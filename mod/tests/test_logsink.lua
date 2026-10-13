-- 日志文件端点与公共时序字段的行为面用例：必须在真帧路径下驱动，不得直调被测面。
-- 驱动链＝真入口 ＋ 真 reload/state/input/source_formb ＋ 真 instant ＋ 真 wiring ＋ 真 logsink；
-- 只桩掉外部边界（读取适配器、内存适配器、随包写面、加载器的日志端点），与既有接线用例同一道边界。
-- 覆盖七件事：①授权构型把日志出口接到加载器端点，且文件首行即端点状态行；
-- ②六类证据行都带公共时序字段（t 秒／f 帧，窗内行再加 w 已开秒），既有字段顺序与文本逐字不变（只追尾）；
-- ③时序与真帧驱动时钟自洽（t 单调不减、0 ≤ w ≤ t、开窗行 w=0）；④落盘行数不超过上界（口径见断言前注释）；
-- ⑤默认构型（端点件缺席）零端点调用、零文件行、控制台输出照旧；⑥端点缺席或打不开即回退控制台且不崩；
-- ⑦名称不合规即不尝试打开端点。

return function(env)
    local reload_lib = env.modules['game/reload']
    local config_lib = env.modules['config']
    local logsink_lib = env.modules['game/logsink']
    env.check(type(logsink_lib) == 'table', '端点模块在用例环境里可加载')

    -- 假地址布局：avatar_manager 全局指针 + 两个组件的管理器表指针 + 两张席位行 + 形态 B 的输入块（席位 0）。
    local GAME_BASE = 0x1000000
    local AVATAR_RVA, AVATAR_MANAGER = 53636384, 0x2200000
    local MAG_MANAGER, ABILITY_MANAGER = 0x2000, 0x2100
    local MAG_TABLE, ABILITY_TABLE = 0x3000, 0x4000
    local MAG_AT, ABILITY_AT = 80, 56
    local RELOAD_MANAGER, RELOAD_TABLE = 0x2200, 0x5000   -- 换弹阶段标志行（写 C 的落点）
    local RELOAD_AT = 80
    local ENTRY_SIZE, ENTRY_INDEX = 32, 10                  -- config.inputs.form_b.entry（常量，用例独立复算）
    local LEVEL_BLOCK = AVATAR_MANAGER + 336 + 7016         -- 域＝解引用 avatar_manager 所得管理器；席位 0
    local ENTRY_AT = LEVEL_BLOCK + ENTRY_INDEX * ENTRY_SIZE -- 条目地址＝块基址 + 条目号*条目宽

    local function u32(value)
        return string.char(value % 0x100, math.floor(value / 0x100) % 0x100,
                           math.floor(value / 0x10000) % 0x100, math.floor(value / 0x1000000) % 0x100)
    end

    local function u64(value)
        local text, rest = '', value
        for _ = 1, 8 do
            text = text .. string.char(rest % 0x100)
            rest = math.floor(rest / 0x100)
        end
        return text
    end

    -- 形态 B 电平：0.0（抬起）与 1.0（按下）的单精度字节，逐字节写死，不走被测面的解码。
    local HELD_UP = string.char(0, 0, 0, 0)
    local HELD_DOWN = string.char(0, 0, 0x80, 0x3F)

    local mem = { store = {} }
    function mem.available() return true end
    function mem.read(self, address, size)
        local text = self.store[address]
        if text == nil or #text < size then return nil end
        return string.sub(text, 1, size)
    end
    function mem.pointer(self, text, offset)
        local value, scale = 0, 1
        for index = 1, 8 do
            local byte = string.byte(text, offset + index)
            if byte == nil then return nil end
            value = value + byte * scale
            scale = scale * 0x100
        end
        return value
    end
    function mem.module_base(self, name) return name == 'game.dll' and GAME_BASE or nil end

    local function put(address, text) mem.store[address] = text end
    local function mem_set(reserve, ammo)
        put(MAG_TABLE, u32(reserve))
        put(MAG_TABLE + 4, u32(ammo))
    end
    local function mem_held(level)
        put(ENTRY_AT, string.rep(string.char(0), 8) .. level .. string.rep(string.char(0), 20))
    end
    local function mem_running(flag) put(ABILITY_TABLE + 16, string.char(flag)) end

    -- 席位表与逐面读数：真 reload.snapshot 会消费这两张面，写入口地址由接线件按公开面自算。
    local rows = { seats = {
        mag = { manager = MAG_MANAGER, index = 0,
                spec = { key = 'mag', arrays = { { at = MAG_AT, stride = 12 } } } },
        ability = { manager = ABILITY_MANAGER, index = 0,
                    spec = { key = 'ability', arrays = { { at = ABILITY_AT, stride = 224 } } } },
        reload = { manager = RELOAD_MANAGER, index = 0,
                   spec = { key = 'reload', arrays = { { at = RELOAD_AT, stride = 4 } } } },
    } }
    local fields = {}
    local recorder = { walked = { seat = 0, avatar = 4096 }, memory = mem,
                       chain = { avatar_manager = AVATAR_RVA } }
    function recorder.set_game(self, value) self.game = value end
    function recorder.slots() return { wield_0 = 4096 } end
    function recorder.components(self, entity) return rows end
    function recorder.fields(self, given) return fields end

    -- 随包写面的桩：形状与真 api 同（write_batch 是 base 优先的点调用，可自称成功而不落字节）。
    local api = { batched = 0, lie = false }
    api.writable_data = function(base, size) return true end
    api.write_batch = function(base, size, changes)
        api.batched = api.batched + 1
        if api.lie then return true, #changes end
        for index = 1, #changes do
            local offset, bytes = changes[index][1], changes[index][2]
            if offset < 0 or offset + #bytes > size then return false, index - 1 end
            put(base + offset, bytes)
        end
        return true, #changes
    end

    -- 双通道捕获：控制台走 print 桩，端点走假句柄（每次写入即落进 chunks，行由换行切分）。
    local said, chunks = {}, {}
    local open_calls, opened_name, flushes, refuse_open = 0, nil, 0, false
    local real_print, real_modules = _G.print, rawget(_G, 'modules')
    local real_loader = rawget(_G, 'CowboyBingusModLoader')
    _G.print = function(...)
        local parts = {}
        for index = 1, select('#', ...) do parts[#parts + 1] = tostring(select(index, ...)) end
        said[#said + 1] = table.concat(parts, ' ')
    end

    local handle = {}
    handle.write = function(self, text) chunks[#chunks + 1] = text end
    handle.flush = function(self) flushes = flushes + 1 end
    local fake_loader = {
        open_log = function(name)
            open_calls = open_calls + 1
            opened_name = name
            if refuse_open then return nil end
            return handle
        end,
        after_startup = function() end,          -- 装配期激活由本用例显式调用，保持时序可控
    }

    local function reset_out()
        said, chunks, open_calls, opened_name, flushes = {}, {}, 0, nil, 0
    end
    local function lines()
        local out = {}
        for index = 1, #chunks do
            for line in string.gmatch(chunks[index], '[^\n]+') do out[#out + 1] = line end
        end
        return out
    end
    local function file_saw(text)
        for _, line in ipairs(lines()) do
            if string.find(line, text, 1, true) ~= nil then return true end
        end
        return false
    end
    local function line_with(text)   -- 取首个含该子串的整行（断言字段位序时用，避免子串跨行误配）
        for _, line in ipairs(lines()) do
            if string.find(line, text, 1, true) ~= nil then return line end
        end
        return nil
    end
    local function file_count(text)
        local seen = 0
        for _, line in ipairs(lines()) do
            if string.find(line, text, 1, true) ~= nil then seen = seen + 1 end
        end
        return seen
    end
    local function console_saw(text)
        for index = 1, #said do
            if string.find(said[index], text, 1, true) ~= nil then return true end
        end
        return false
    end
    -- 时序字段解析：字段名带前置空格，避免与行内其它键误配。
    local function field_of(text, key)
        local value = string.match(text, key .. '=([%-%d%.]+)')
        return value ~= nil and tonumber(value) or nil
    end

    local saved_access, saved_memory = env.modules['game/access'], env.modules['game/memory']
    local saved_vendor_memory = env.modules['game/vendor/bingus_memory']
    local saved_vendor_write = env.modules['game/vendor/bingus_write']
    local saved_name = config_lib.log.name
    -- 自测宿主把全部用例内联进同一进程，容量槽是全进程唯一的共享状态；新用例必须自己把它复位，
    -- 否则前面的用例采过的容量会留在槽里，本节「未采集即拒写」就不再是第一档。
    local saved_capacity = config_lib.instant.capacity_default
    config_lib.instant.capacity_default = nil
    env.modules['game/access'] = { new = function() return recorder end }
    env.modules['game/memory'] = { new = function() return mem end }
    env.modules['game/vendor/bingus_memory'] = { new = function() return api end }
    env.modules['game/vendor/bingus_write'] = { extend = function(target) return target end }

    -- 入口跑多次（授权构型／默认构型／端点失败档），每次都截下触发器的引用，用于读闸门与注入点。
    local trigger = nil
    local real_reload_new = reload_lib.new
    env.modules['game/reload'] = setmetatable({
        new = function(request, access)
            local object = real_reload_new(request, access)
            trigger = object
            return object
        end,
    }, { __index = reload_lib })

    _G.modules = env.modules
    local function run_entry()
        trigger = nil
        local ok, system = pcall(env.entry)
        if not ok or type(system) ~= 'table' then
            env.check(false, '入口装配失败：' .. tostring(system))
            return nil
        end
        system.activate()
        return system
    end

    local function restore()
        _G.print, _G.modules = real_print, real_modules
        _G.CowboyBingusModLoader = real_loader
        env.modules['game/access'], env.modules['game/memory'] = saved_access, saved_memory
        env.modules['game/vendor/bingus_memory'] = saved_vendor_memory
        env.modules['game/vendor/bingus_write'] = saved_vendor_write
        config_lib.log.name = saved_name
        config_lib.instant.capacity_default = saved_capacity
    end

    math.randomseed(20261005)
    put(MAG_MANAGER + MAG_AT, u64(MAG_TABLE))       -- 管理器侧的数组表指针（接线件自算行地址的起点）
    put(ABILITY_MANAGER + ABILITY_AT, u64(ABILITY_TABLE))
    put(RELOAD_MANAGER + RELOAD_AT, u64(RELOAD_TABLE))
    put(RELOAD_TABLE, u32(4))                       -- 换弹阶段标志初值（写入前快照值）
    put(GAME_BASE + AVATAR_RVA, u64(AVATAR_MANAGER)) -- avatar_manager 全局指针（形态 B 取址的前置解引用）
    mem_set(90, 0)
    mem_running(0)
    mem_held(HELD_UP)
    fields.reloading, fields.mag_reserve, fields.mag_ammo = 0, 90, 0
    fields.reload_stage, fields.ability_running = 0, 0
    fields.raw_wielded_by, fields.mag_chamber_round, fields.ability_id = 4096, 0, 7
    fields.seat = 0

    local function idle(sys, seconds)
        mem_held(HELD_UP)
        fields.reloading = 0
        sys.frame(seconds)
    end

    -- 开窗：本帧 reloading 由假转真（'start' 边沿会让状态机重开一轮，故定位必须排在开窗之后）。
    local function open_window(sys, seconds)
        mem_held(HELD_UP)
        fields.reloading = 1
        sys.frame(seconds)
    end

    -- 关窗：本帧 reloading 由真转假（容量首装自收集就发生在这一帧）。
    local function close_window(sys, seconds)
        mem_held(HELD_UP)
        fields.reloading = 0
        sys.frame(seconds)
    end

    -- 窗内按一次：先把扫过位置推到区间中点，再按下（按帧不推进时间，位置不动）。
    -- 窗口尚未打开时先补一帧开窗：'start' 边沿会在那一帧重开状态机，begin 必须排在开窗帧之后，
    -- 否则位置被推到区间外、press 记 miss、写路径根本不被调用。
    local function press_in_window(sys, seconds)
        if fields.reloading ~= 1 then
            open_window(sys, seconds or 0.016)
        end
        local start_at, finish_at = sys.begin(1.0)
        mem_held(HELD_UP)
        sys.frame((start_at + finish_at) / 2)
        mem_held(HELD_DOWN)
        sys.frame(0)
        return start_at, finish_at
    end

    -- 一、授权构型：端点件在场 ⇒ 日志出口换成加载器文件端点（申请恰好一次，首行即端点状态行）。
    _G.CowboyBingusModLoader = fake_loader
    reset_out()
    local system = run_entry()
    if system == nil then
        restore()
        return
    end
    env.equal(open_calls, 1, '装配期向加载器申请端点恰好一次')
    env.equal(opened_name, config_lib.log.name, '申请的文件名取自配置键（逐字一致）')
    env.equal(config_lib.log.name, 'ActiveReload.log', '配置键的缺省值就是正典文件名')
    env.equal(lines()[1], 'LOG sink=file name=ActiveReload.log', '文件首行是端点状态行（端点确已生效）')
    env.check(flushes >= 1, '每行写入后立即冲刷（已冲刷 ' .. tostring(flushes) .. ' 次）')
    env.equal(type(trigger.request), 'function', '授权构型的写入口已接线（本用例要的是真帧路径）')

    idle(system, 0.016)
    idle(system, 0.016)
    open_window(system, 0.016)
    local open_line = line_with('WINDOW open ')
    env.check(open_line ~= nil and string.find(open_line, ' wield0=', 1, true) ~= nil
        and string.find(open_line, ' mag_ammo=', 1, true) ~= nil
        and string.find(open_line, ' t=', 1, true) ~= nil,
        '开窗行带 wield0／mag_ammo／t 字段（新字段在既有字段位之后）')
    press_in_window(system)
    env.check(file_saw('PRESS window capacity=none t='), '窗内按压行带 t 字段、既有容量字段位置不变')
    env.check(file_saw('WRITE status=refused reason=no-capacity'), '容量未采集时的拒绝行照旧落进文件')
    close_window(system, 0.016)
    local close_line = line_with('WINDOW close ')
    env.check(close_line ~= nil and string.find(close_line, 'capacity=none', 1, true) ~= nil
        and string.find(close_line, ' wield0=', 1, true) ~= nil
        and string.find(close_line, ' mag_ammo=', 1, true) ~= nil
        and string.find(close_line, ' t=', 1, true) ~= nil,
        '关窗行带 capacity／wield0／mag_ammo／t 字段')

    -- 一·1 两路读数首次置位各落一行（入口两路判定同处一条 if/elseif 链，故各用一窗观测）。
    fields.ability_running, fields.reload_stage = 1, 0
    open_window(system, 0.016)
    fields.ability_running = 0
    system.frame(0.016)
    close_window(system, 0.016)

    fields.ability_running, fields.reload_stage = 0, 4
    open_window(system, 0.016)
    fields.reload_stage = 0
    system.frame(0.016)
    close_window(system, 0.016)

    -- 一·2 自然换弹完成那一帧采集容量，之后窗内按压 ⇒ 真写入，写入行带已回读的弹药值。
    mem_set(10, 5)
    fields.mag_reserve, fields.mag_ammo = 10, 5
    open_window(system, 0.016)
    close_window(system, 0.016)
    local cap_line = line_with('WINDOW close capacity=5')
    env.check(cap_line ~= nil and string.find(cap_line, ' wield0=', 1, true) ~= nil
        and string.find(cap_line, ' mag_ammo=', 1, true) ~= nil
        and string.find(cap_line, ' t=', 1, true) ~= nil,
        '容量采集那一窗的关窗行带容量与 wield0／mag_ammo／t 字段')

    mem_set(10, 0)
    fields.mag_reserve, fields.mag_ammo = 10, 0
    press_in_window(system)
    close_window(system, 0.016)
    local write_lines = {}
    for _, line in ipairs(lines()) do
        if string.find(line, 'WRITE status=written', 1, true) ~= nil then write_lines[#write_lines + 1] = line end
    end
    env.check(#write_lines == 1, '写入成功行恰一行（实得 ' .. tostring(#write_lines) .. '：' ..
              table.concat(write_lines, ' | ') .. '）')
    env.check(#write_lines == 1 and string.find(write_lines[1],
              'WRITE status=written reason=none calls=2 reserve=9 ammo=5 capacity=5 t=', 1, true) ~= nil,
              '写入行的既有字段顺序与文本逐字不变，时序字段只追加在行尾（实得 ' ..
              table.concat(write_lines, ' | ') .. '）')

    -- 一·3 回读不符 ⇒ 回写双快照，结果行与回滚行都落进文件。
    -- 真机两次换弹之间隔数秒，这里先把窗口连续关闭超过延续阈值，写入锁存才会放开。
    idle(system, 0.9)
    idle(system, 0.9)
    idle(system, 0.9)
    idle(system, 0.9)
    idle(system, 0.9)
    mem_set(10, 0)
    fields.mag_reserve, fields.mag_ammo = 10, 0
    api.lie = true
    press_in_window(system)
    api.lie = false
    close_window(system, 0.016)
    env.check(file_saw('WRITE status=voided'), '回读不符时结果行如实报 voided')
    env.check(file_saw('ROLLBACK reason=readback-mismatch reserve=10 ammo=0 t='),
              '回滚行的既有字段顺序不变、时序字段追加在行尾')

    -- 一·4 时序自洽、字段覆盖与替换式出口。
    local last_t, last_f, window_lines, stamped = -1, -1, 0, 0
    for _, line in ipairs(lines()) do
        local seconds, frames = field_of(line, ' t'), field_of(line, ' f')
        if seconds ~= nil then
            env.check(seconds >= last_t, '时序列单调不减（t=' .. tostring(seconds) .. '）')
            env.check(frames ~= nil, '带 t 的行同时带 f 字段（两个时序字段同源同现）')
            last_t = seconds
        end
        if frames ~= nil then
            env.check(frames >= last_f, '帧号序列单调不减（f=' .. tostring(frames) .. '）')
            last_f = frames
        end
        local with_window = field_of(line, ' w')
        if with_window ~= nil then
            stamped = stamped + 1
            env.check(with_window >= 0 and seconds ~= nil and with_window <= seconds,
                      '窗内已开秒落在 [0, t]（w=' .. tostring(with_window) .. ' t=' .. tostring(seconds) .. '）')
        end
        if string.find(line, 'WINDOW open', 1, true) ~= nil then
            window_lines = window_lines + 1
            env.check(field_of(line, ' w') == 0, '开窗行把本窗起点记成 w=0')
        end
    end
    env.check(stamped >= 6, '窗内行确实带了 w 字段（共 ' .. tostring(stamped) .. ' 行）')
    env.check(last_t > 0, '时序列取自帧驱动时钟（末值 t=' .. tostring(last_t) .. '）')
    env.equal(logsink_lib.stats.dropped, 0, '端点写入全程零失败（无丢行）')
    env.check(not console_saw('WINDOW open'), '授权构型下证据行不再走控制台（替换，不是双写）')

    -- 落盘行数上界（口径）：1 行端点状态行 ＋ 每窗至多 8 行（开窗／关窗／窗内按压／写入结果／回滚／
    -- 弃写拒因／写后快照当帧 step=1／写后快照次帧 step=2 各至多 1 行）＋ 2 行首次置位（两路读数各 1 行，
    -- 全程去重）；窗数 W 由实际落盘的开窗行数读出。
    env.check(window_lines >= 6, '本用例至少驱动了 6 个窗口（实得 ' .. tostring(window_lines) .. '）')
    env.check(#lines() <= 3 + 8 * window_lines,
              '落盘行数不超过上界（实得 ' .. tostring(#lines()) .. ' 行，上界 ' ..
              tostring(3 + 8 * window_lines) .. ' 行，W=' .. tostring(window_lines) .. '）')

    -- 二、默认构型：端点件与接线件一并缺席（真默认模块集）⇒ 零端点调用、零落盘，控制台输出照旧。
    local sink_saved, wiring_saved = env.modules['game/logsink'], env.modules['game/wiring']
    env.modules['game/logsink'], env.modules['game/wiring'] = nil, nil
    reset_out()
    local default_system = run_entry()
    if default_system ~= nil then
        env.equal(open_calls, 0, '默认构型一次端点调用都没有')
        env.equal(#chunks, 0, '默认构型没有任何落盘写入')
        idle(default_system, 0.016)
        open_window(default_system, 0.016)
        press_in_window(default_system)
        close_window(default_system, 0.016)
        env.check(console_saw('INPUT source=form_b spec=8c041a6e'), '默认构型控制台输出照旧（取源回显逐字不变）')
        env.check(not console_saw('LOG sink='), '默认构型不打印任何端点状态行')
        env.check(not console_saw('WINDOW '), '默认构型没有任何窗口证据行（出口与接线一并缺席）')
    end
    env.modules['game/logsink'], env.modules['game/wiring'] = sink_saved, wiring_saved

    -- 三、端点件在场但没有加载器 ⇒ 回退控制台，不崩、不落盘。
    _G.CowboyBingusModLoader = nil
    reset_out()
    local bare_system = run_entry()
    if bare_system ~= nil then
        env.equal(open_calls, 0, '没有加载器时不申请端点')
        env.equal(#chunks, 0, '没有加载器时不落盘')
        idle(bare_system, 0.016)
        open_window(bare_system, 0.016)
        env.check(console_saw('WINDOW open'), '端点缺席即回退控制台，证据行照旧落下')
        close_window(bare_system, 0.016)
    end

    -- 四、加载器在场但端点打不开 ⇒ 同样回退控制台。
    _G.CowboyBingusModLoader = fake_loader
    refuse_open = true
    reset_out()
    local refused_system = run_entry()
    if refused_system ~= nil then
        env.equal(open_calls, 1, '申请了端点但加载器返回空')
        env.equal(#chunks, 0, '端点打不开时不落盘')
        idle(refused_system, 0.016)
        open_window(refused_system, 0.016)
        env.check(console_saw('WINDOW open'), '端点打不开即回退控制台，不崩且证据行照旧')
        close_window(refused_system, 0.016)
    end
    refuse_open = false

    -- 五、名称不合规（含文件名缺席）即不申请端点。
    config_lib.log.name = 'bad.txt'
    reset_out()
    local bad_system = run_entry()
    if bad_system ~= nil then
        env.equal(open_calls, 0, '名称不合规时不申请端点')
        env.equal(#chunks, 0, '名称不合规时不落盘')
        env.check(console_saw('INPUT source=form_b spec=8c041a6e'), '名称不合规即回退控制台，输出照旧')
    end
    config_lib.log.name = nil
    reset_out()
    local none_system = run_entry()
    if none_system ~= nil then
        env.equal(open_calls, 0, '文件名缺席时同样不申请端点')
        env.equal(#chunks, 0, '文件名缺席时同样不落盘')
    end

    restore()
end
