-- 写路径接线与容量武装的行为面用例（必须驱动真帧路径）。
-- 驱动链＝真入口 ＋ 真 reload/state/input/source_formb ＋ 真 instant ＋ 真 wiring；
-- 只桩掉外部边界（access 适配器、内存适配器、随包写面），与 test_entry 同一道边界。
-- 覆盖四件事：①授权装配（A-2：模块在场自判）把 request 注入 reload.send 的唯一实现点；
-- ②默认装配（写路径模块缺席）闸门维持假、send 逐字回 false,'disabled'、证据行一行不落；
-- ③容量未采集即 refused no-capacity，采集成功后 written 且写入结果行带已回读的弹药值（验收 A1）；
-- ④回读不符走回滚（voided ＋ ROLLBACK 行）。所有读数一律经 system.frame 驱动，不直调被测面。

return function(env)
    local reload_lib = env.modules['game/reload']
    local wiring_lib = env.modules['game/wiring']

    -- 假地址布局：avatar_manager 全局指针 + 两个组件的管理器表指针 + 两张席位行 + 形态 B 的输入块（席位 0）。
    local GAME_BASE = 0x1000000
    local AVATAR_RVA, AVATAR_MANAGER = 53636384, 0x2200000
    local MAG_MANAGER, ABILITY_MANAGER = 0x2000, 0x2100
    local MAG_TABLE, ABILITY_TABLE = 0x3000, 0x4000
    local MAG_AT, ABILITY_AT = 80, 56
    local RELOAD_MANAGER, RELOAD_TABLE = 0x2200, 0x5000   -- 换弹阶段标志行（F1 写 C 的落点）
    local RELOAD_AT = 80
    local ENTRY_SIZE, ENTRY_INDEX = 32, 10                  -- config.inputs.form_b.entry（常量，用例独立复算）
    local LEVEL_BLOCK = AVATAR_MANAGER + 336 + 7016         -- 域＝解引用 avatar_manager 所得管理器；席位 0
    local ENTRY_AT = LEVEL_BLOCK + ENTRY_INDEX * ENTRY_SIZE -- 条目地址＝块基址 + 条目号*条目宽

    local function u32(value)
        return string.char(value % 0x100, math.floor(value / 0x100) % 0x100,
                           math.floor(value / 0x10000) % 0x100, math.floor(value / 0x1000000) % 0x100)
    end

    local function u64(value)
        local text = ''
        local rest = value
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
    function mem.module_base(self, name)
        return name == 'game.dll' and GAME_BASE or nil
    end

    local function put(address, text) mem.store[address] = text end
    local function u32_at(address)
        local a, b, c, d = string.byte(mem.store[address] or '', 1, 4)
        if a == nil then return -1 end
        return a + b * 0x100 + c * 0x10000 + d * 0x1000000
    end
    local function mem_set(reserve, ammo)
        put(MAG_TABLE, u32(reserve))
        put(MAG_TABLE + 4, u32(ammo))
    end
    local function mem_held(level)
        put(ENTRY_AT, string.rep(string.char(0), 8) .. level .. string.rep(string.char(0), 20))
    end
    local function mem_running(flag)
        put(ABILITY_TABLE + 16, string.char(flag))
    end

    -- 席位表与逐面读数：真 reload.snapshot 会消费这两张面，写入地址由 wiring 按公开面自算。
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

    -- 随包写面的桩：契约与 bingus_write.extend 装出来的 api 同形（write_batch 是 base 优先的点调用）。
    local api = { batched = 0, lie = false, windows = {} }
    api.writable_data = function(base, size) return true end
    api.write_batch = function(base, size, changes)
        api.batched = api.batched + 1
        if api.lie then return true, #changes end        -- 场景：自称成功但不落字节（逼出回滚）
        for index = 1, #changes do
            local offset, bytes = changes[index][1], changes[index][2]
            if offset < 0 or offset + #bytes > size then return false, index - 1 end
            put(base + offset, bytes)
        end
        return true, #changes
    end

    local said = {}
    local real_print = _G.print
    local real_modules = rawget(_G, 'modules')
    local real_loader = rawget(_G, 'CowboyBingusModLoader')
    _G.print = function(...)
        local parts = {}
        for index = 1, select('#', ...) do
            parts[#parts + 1] = tostring(select(index, ...))
        end
        said[#said + 1] = table.concat(parts, ' ')
    end
    _G.CowboyBingusModLoader = nil

    local function saw(text)
        for index = 1, #said do
            if string.find(said[index], text, 1, true) ~= nil then return true end
        end
        return false
    end

    local function count(text)
        local seen = 0
        for index = 1, #said do
            if string.find(said[index], text, 1, true) ~= nil then seen = seen + 1 end
        end
        return seen
    end

    local function line_of(text)
        for index = 1, #said do
            if string.find(said[index], text, 1, true) ~= nil then return said[index] end
        end
        return nil
    end

    local saved_access, saved_memory = env.modules['game/access'], env.modules['game/memory']
    local saved_vendor_memory = env.modules['game/vendor/bingus_memory']
    local saved_vendor_write = env.modules['game/vendor/bingus_write']
    env.modules['game/access'] = { new = function() return recorder end }
    env.modules['game/memory'] = { new = function() return mem end }
    env.modules['game/vendor/bingus_memory'] = { new = function() return api end }
    env.modules['game/vendor/bingus_write'] = { extend = function(target) return target end }

    -- 入口跑两次（默认构型 / 授权构型），每次都截下触发器的引用，用于读闸门与 request 注入点。
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

    math.randomseed(20261005)
    put(MAG_MANAGER + MAG_AT, u64(MAG_TABLE))       -- 管理器侧的数组表指针（wiring 自算行地址的起点）
    put(ABILITY_MANAGER + ABILITY_AT, u64(ABILITY_TABLE))
    put(RELOAD_MANAGER + RELOAD_AT, u64(RELOAD_TABLE))
    put(RELOAD_TABLE, u32(4))                       -- 换弹阶段标志初值 4（写入前快照值，回滚基线）
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

    -- 让写入锁存过期：窗口连续关闭且时钟推进超过延续阈值（config.bar.hold_seconds＝3.2 秒）。
    -- 首帧只记起点，故需 5 帧 0.9 秒（其后累计 3.6 秒 > 3.2 秒）才放开。
    -- 真机里两次换弹之间隔数秒，故独立用例之间必须先过阈值，锁存才不会跨用例残留。
    local function settle(sys)
        mem_held(HELD_UP)
        fields.reloading = 0
        sys.frame(0.9)
        sys.frame(0.9)
        sys.frame(0.9)
        sys.frame(0.9)
        sys.frame(0.9)
    end

    -- 窗内按一次：先把扫过位置推到区间中点，再按下（按帧不推进时间，位置不动）。
    -- 窗口尚未打开时先补一帧开窗：'start' 边沿会在那一帧重开状态机（用上一窗实测时长当基），
    -- 所以 begin(1.0) 必须排在开窗帧之后，否则位置被推到区间外、press 记 miss、写路径根本不被调用。
    local function press_in_window(sys, seconds)
        if fields.reloading ~= 1 then
            open_window(sys, seconds or 0.016)
        end
        local start_at, finish_at = sys.begin(1.0)      -- sweep_start = 0.0 ⇒ position = elapsed/duration
        mem_held(HELD_UP)
        sys.frame((start_at + finish_at) / 2)
        mem_held(HELD_DOWN)
        sys.frame(0)
        return start_at, finish_at
    end

    -- 一、默认构型：写路径模块缺席 ⇒ 闸门维持关、send 逐字回 disabled、不落任何证据行。
    local wiring_saved = env.modules['game/wiring']
    env.modules['game/wiring'] = nil
    local default_system = run_entry()
    if default_system ~= nil then
        env.check(trigger ~= nil, '默认构型下触发器已构造（用于读闸门）')
        env.equal(trigger.instant_enabled, false, '默认构型闸门维持假（连线前的逐字同义）')
        env.equal(trigger.request, nil, '默认构型不注入 request（唯一实现点缺席）')
        local config_lib = env.modules['config']
        env.check(config_lib ~= nil and config_lib.instant ~= nil
                  and config_lib.instant.enabled == false,
                  '默认构型不把闸门配置翻真（config.instant.enabled 维持假）')
        env.equal(reload_lib.send(trigger), false, '默认构型 send 回假')
        env.equal(select(2, reload_lib.send(trigger)), 'disabled', '默认构型 send 的原因逐字是 disabled')
        idle(default_system, 0.016)
        idle(default_system, 0.016)
        open_window(default_system, 0.016)
        press_in_window(default_system)
        close_window(default_system, 0.016)
        env.check(not saw('WRITE '), '默认构型没有任何写入结果行')
        env.check(not saw('WINDOW '), '默认构型没有任何窗口证据行（接线缺席 ⇒ 证据行一行不落）')
        env.check(saw('INPUT source=form_b spec=8c041a6e'), '默认构型的装配期取源回显逐字不变')
    end
    env.modules['game/wiring'] = wiring_saved

    -- 二、授权构型：接线在场 ⇒ 闸门开、写路径武装。
    local authorized_system = run_entry()
    if authorized_system == nil then
        _G.print, _G.modules, _G.CowboyBingusModLoader = real_print, real_modules, real_loader
        env.modules['game/access'], env.modules['game/memory'] = saved_access, saved_memory
        env.modules['game/vendor/bingus_memory'] = saved_vendor_memory
        env.modules['game/vendor/bingus_write'] = saved_vendor_write
        return
    end
    env.check(trigger ~= nil, '授权构型下触发器已构造')
    env.equal(trigger.instant_enabled, true, '授权构型闸门已开（A-2 模块在场自判）')
    env.equal(type(trigger.request), 'function', '授权构型把 request 注入唯一实现点')
    env.check(wiring_lib ~= nil, '授权构型的写路径接线模块在场')
    env.check(env.modules['config'].instant.enabled == true,
              '授权构型经 A-2 把闸门配置翻真（模块在场是唯一差异轴）')

    idle(authorized_system, 0.016)
    idle(authorized_system, 0.016)
    env.check(not saw('WRITE '), '尚未进入窗口时没有写入结果行')

    -- 二·1 窗口边沿 + 窗内按压 + 容量未采集的拒绝（本段是「未采集即拒」的见证）。
    open_window(authorized_system, 0.016)
    env.check(saw('WINDOW open'), '开窗帧落窗口证据行')
    press_in_window(authorized_system)
    env.check(saw('PRESS window '), '窗内按压落按压证据行')
    env.check(saw('WRITE status=refused reason=no-capacity'), '容量未采集时写入被拒（no-capacity）')
    env.equal(api.batched, 0, '容量未采集时一次写调用都没有落下去')
    close_window(authorized_system, 0.016)
    env.check(saw('WINDOW close capacity=none'), '关窗帧落关窗证据行；零弹容量不认（>0 校验）')

    -- 二·2 窗口内两路读数首次置位各落一行。
    -- 入口的两路读数判定是同一 if/elseif 链（:211/:213）⇒ 一次开窗内两路互斥上报，故各用一窗观测。
    fields.ability_running, fields.reload_stage = 1, 0
    open_window(authorized_system, 0.016)
    fields.ability_running = 0
    authorized_system.frame(0.016)
    env.check(saw('OBSERVED ability=0'), '窗口内 ability_running 转假落一行')
    close_window(authorized_system, 0.016)

    fields.ability_running, fields.reload_stage = 0, 4
    open_window(authorized_system, 0.016)
    fields.reload_stage = 0
    authorized_system.frame(0.016)
    env.check(saw('OBSERVED stage=0'), '窗口内 reload_stage 归零落一行')
    close_window(authorized_system, 0.016)

    env.equal(count('OBSERVED ability=0'), 1, '首次置位只落一行（不刷屏）')
    env.equal(count('OBSERVED stage=0'), 1, '首次置位只落一行（不刷屏）')
    close_window(authorized_system, 0.016)

    -- 二·3 自然换弹完成那一帧采集容量。
    mem_set(10, 5)
    fields.mag_reserve, fields.mag_ammo = 10, 5
    open_window(authorized_system, 0.016)
    close_window(authorized_system, 0.016)
    env.check(saw('WINDOW close capacity=5'), '自然换弹完成后采集到容量 5（首装自收集）')

    -- 二·4 采集后窗内按压 ⇒ 真写入，且写入结果行带上已回读的弹药值（验收 A1）。
    mem_set(10, 0)
    fields.mag_reserve, fields.mag_ammo = 10, 0
    local before_store = {}
    for address, text in pairs(mem.store) do before_store[address] = text end
    press_in_window(authorized_system)
    env.equal(u32_at(MAG_TABLE + 4), 5, '弹匣被补满至采集到的容量')
    env.equal(u32_at(MAG_TABLE), 9, '备弹按整匣扣减（10 - 1）')
    env.equal(u32_at(RELOAD_TABLE), 0, '换弹阶段标志被同批补写为 0（F1 写 C；写前快照值 4）')
    -- 写集外零触碰：只允许四个写目标地址发生变化（ENTRY_AT 是用例自身写的输入电平，不算被测面写集）
    local allowed = { [MAG_TABLE] = true, [MAG_TABLE + 4] = true, [ABILITY_TABLE + 16] = true,
                      [RELOAD_TABLE] = true, [ENTRY_AT] = true }
    local stray = 0
    for address, text in pairs(mem.store) do
        if before_store[address] ~= text and allowed[address] ~= true then stray = stray + 1 end
    end
    env.equal(stray, 0, '写集外零触碰（只动 mag.reserve／mag.ammo／ability.running／reload.stage 四处）')
    local f1_report = rawget(_G, '__report')
    if f1_report ~= nil then
        f1_report('二·4 F1-写后阶段标志 reload_stage=' .. tostring(u32_at(RELOAD_TABLE)) ..
                  '（写前快照值 4）')
        f1_report('二·4 F1-写集外零触碰 stray=' .. tostring(stray) ..
                  '（允许面：mag.reserve／mag.ammo／ability.running／reload.stage）')
    end
    env.check(saw('WRITE status=written'), '写入成功落写入结果行')
    env.check(saw('reserve=9 ammo=5 capacity=5'), '写入结果行带已回读的弹药值与本次容量')
    env.check(not saw('ROLLBACK'), '写入与回读一致时不落回滚行')

    -- 二·5 回读不符 ⇒ 回写双快照并把结果行与回滚行都落下来。
    settle(authorized_system)
    mem_set(90, 10)
    fields.mag_reserve, fields.mag_ammo = 90, 10
    api.lie = true
    press_in_window(authorized_system)
    api.lie = false
    env.check(saw('WRITE status=voided'), '回读不符时写入结果行如实报 voided')
    env.check(saw('ROLLBACK reason=readback-mismatch'), '回写双快照后落回滚证据行')
    env.equal(u32_at(MAG_TABLE + 4), 10, '回滚后弹匣值回到原样（假写面未落字节）')
    env.equal(u32_at(MAG_TABLE), 90, '回滚后余弹值回到原样（假写面未落字节）')
    env.check(count('WRITE ') >= 3, '本用例全程只用 system.frame 驱动 ⇒ 三行以上写入结果行来自真帧路径')

    -- 二·6 写后快照行：写成功当帧落 step=1、次帧落 step=2，其后按帧偏移继续采样（纯诊断，不做补救性写入）。
    env.check(saw('AFTERWRITE step=1'), '写成功当帧落写后快照行（step=1）')
    env.check(saw('AFTERWRITE step=2'), '写成功次帧落写后快照行（step=2）')
    local first_after = line_of('AFTERWRITE step=1')
    env.check(first_after ~= nil
              and string.find(first_after, ' reloading=', 1, true) ~= nil
              and string.find(first_after, ' reload_stage=', 1, true) ~= nil
              and string.find(first_after, ' ability_running=', 1, true) ~= nil
              and string.find(first_after, ' mag_ammo=', 1, true) ~= nil
              and string.find(first_after, ' mag_reserve=', 1, true) ~= nil
              and string.find(first_after, ' wield0=', 1, true) ~= nil,
              '写后快照行带 reloading 与状态机字段面读数（reloading/reload_stage/ability_running/mag_ammo/mag_reserve/wield0）')

    -- 二·7 落窗按压未达写路径 ⇒ 次帧落弃写拒因行（写入率判读面；复用 WRITE 家族，不新增顶层 token）。
    -- 不重开扫过区间：把时钟推过本窗区间终点 ⇒ 位置落在区间外，按压记 miss、写路径不被调用。
    mem_held(HELD_UP)
    authorized_system.frame(1.5)
    mem_held(HELD_DOWN)
    authorized_system.frame(0)
    env.equal(count('WRITE status=abandoned'), 0, '弃写拒因行不在按压当帧落（留给次帧销账）')
    authorized_system.frame(0.016)
    env.check(saw('WRITE status=abandoned reason=no-hit'), '按压未达写路径 ⇒ 次帧落具名拒因行')
    env.equal(count('WRITE status=abandoned'), 1, '拒因行逐次销账，不重复刷行')

    -- 二·8 写后六步采样：步 1 当帧／步 2 次帧／步 3／4／5 按帧偏移 +0x1E／+0x5A／+0x87 帧／步 6 wield0 变化后首帧；
    --      采样窗独立于窗口生命期（按帧计数驱动，窗口关闭不终止）；纯诊断，零补救性写入。
    for index = #said, 1, -1 do said[index] = nil end        -- 本用例独立取证：清空此前证据行
    local function idle_frames(howmany)
        for _ = 1, howmany do
            mem_held(HELD_UP)
            fields.reloading = 0
            authorized_system.frame(0)
        end
    end
    local report = rawget(_G, '__report')
    local function emit(tag, line)
        if report ~= nil and line ~= nil then report('二·8 ' .. tag .. ' ' .. line) end
    end
    idle_frames(0x8C)                                        -- 清干前一写入的残余采样序列（步 5 后自然停摆）
    for index = #said, 1, -1 do said[index] = nil end
    fields.wield_0 = 4096
    mem_set(90, 10)
    fields.mag_reserve, fields.mag_ammo = 90, 10
    press_in_window(authorized_system)
    local one = line_of('AFTERWRITE step=1')
    env.check(one ~= nil and string.find(one, 'reloading=', 1, true) ~= nil,
              '写成功当帧落步 1 行且带 reloading 字段')
    env.check(not saw('AFTERWRITE step=2'), '当帧不落步 2 行（次帧才落）')
    close_window(authorized_system, 0.016)
    local two = line_of('AFTERWRITE step=2')
    env.check(two ~= nil, '次帧落步 2 行（窗口已关，采样继续）')
    env.check(not saw('AFTERWRITE step=3'), '未到 +0x1E 帧不落步 3 行')
    idle_frames(0x1D)
    local three = line_of('AFTERWRITE step=3')
    env.check(three ~= nil, '到 +0x1E 帧落步 3 行（窗口关闭不终止采样）')
    idle_frames(0x3C)
    local four = line_of('AFTERWRITE step=4')
    env.check(four ~= nil, '到 +0x5A 帧落步 4 行')
    idle_frames(0x2D)
    local five = line_of('AFTERWRITE step=5')
    env.check(five ~= nil, '到 +0x87 帧落步 5 行')
    env.check(not saw('AFTERWRITE step=6'), 'wield0 未变化不落步 6 行')
    fields.wield_0 = 455
    authorized_system.frame(0)
    local six = line_of('AFTERWRITE step=6')
    env.check(six ~= nil, 'wield0 变化后首帧落步 6 行')
    emit('写后采样-步1', one)
    emit('写后采样-步2', two)
    emit('写后采样-步3', three)
    emit('写后采样-步4', four)
    emit('写后采样-步5', five)
    emit('写后采样-步6', six)

    -- 二·9 静音窗自证的一次性标志（仪器面修复）：到阈值只落一行，计数停在阈值时不得重发。
    local function muted_window()
        open_window(authorized_system, 0.016)
        close_window(authorized_system, 0.016)      -- 整窗无真电平 ⇒ 计一个静音窗
    end
    muted_window(); muted_window(); muted_window()
    press_in_window(authorized_system)              -- 该窗有真电平：计数不增
    close_window(authorized_system, 0.016)
    muted_window()
    env.equal(authorized_system.observed ~= nil and authorized_system.observed.mute_reported == true,
              true, '静音窗到阈值后一次性标志置位（mute_reported；计数停在阈值也不重发）')
    env.check(count('INPUT-B-MUTE windows=') <= 1, '本用例全程静音窗行不超过一行（不重发）')

    -- 二·10 账目单位（端到端接线见证）：mag_reserve 是弹匣计数、每写扣 1 整匣、弹匣补满（与自然换弹同额）。
    --       备弹 4 匣、写入时弹匣被换弹动画清零 ⇒ 弹匣补至容量 5、备弹扣 1 匣（旧跨单位算式会按补差多发多扣）。
    for index = #said, 1, -1 do said[index] = nil end
    settle(authorized_system)
    mem_set(4, 0)
    fields.mag_reserve, fields.mag_ammo = 4, 0
    press_in_window(authorized_system)
    env.equal(u32_at(MAG_TABLE + 4), 5, '弹匣补满至容量 5')
    env.equal(u32_at(MAG_TABLE), 3, '备弹按整匣扣减（4 - 1 = 3）')
    local unit_line = line_of('WRITE status=written')
    if report ~= nil and unit_line ~= nil then
        report('二·10 账目单位-写入行 ' .. unit_line)
    end
    close_window(authorized_system, 0.016)

    -- 二·11 写入锁存（判定层硬防护）：同一次换弹成功写过一次后，窗内再按不再写入（只落 already-written）；
    --       窗口连续关闭超过延续阈值后锁存放开，下一次换弹照常写入。
    for index = #said, 1, -1 do said[index] = nil end
    settle(authorized_system)
    mem_set(6, 0)
    fields.mag_reserve, fields.mag_ammo = 6, 0
    press_in_window(authorized_system)
    env.equal(u32_at(MAG_TABLE + 4), 5, '锁存用例首次按压补满弹匣')
    env.equal(u32_at(MAG_TABLE), 5, '锁存用例首次按压扣一匣（6 - 1 = 5）')
    press_in_window(authorized_system)
    env.equal(u32_at(MAG_TABLE), 5, '锁存期内再按不再扣备弹')
    env.equal(u32_at(MAG_TABLE + 4), 5, '锁存期内再按不改弹匣')
    authorized_system.frame(0.016)
    env.check(saw('WRITE status=abandoned reason=already-written'), '锁存期内再按落 already-written 拒因行')
    env.equal(count('WRITE status=written'), 1, '锁存期内只成功写入一次')
    close_window(authorized_system, 0.016)
    settle(authorized_system)
    mem_set(3, 0)
    fields.mag_reserve, fields.mag_ammo = 3, 0
    press_in_window(authorized_system)
    env.equal(u32_at(MAG_TABLE), 2, '锁存放开后新换弹照常写入（3 - 1 = 2）')
    env.equal(u32_at(MAG_TABLE + 4), 5, '新换弹弹匣补满至容量')
    real_print(string.format('WRITE LATCH written=%d already-written=%d reopen-reserve=%d reopen-ammo=%d',
                             count('WRITE status=written'),
                             count('WRITE status=abandoned reason=already-written'),
                             u32_at(MAG_TABLE), u32_at(MAG_TABLE + 4)))
    close_window(authorized_system, 0.016)

    _G.print, _G.modules, _G.CowboyBingusModLoader = real_print, real_modules, real_loader
    env.modules['game/access'], env.modules['game/memory'] = saved_access, saved_memory
    env.modules['game/vendor/bingus_memory'] = saved_vendor_memory
    env.modules['game/vendor/bingus_write'] = saved_vendor_write
end
