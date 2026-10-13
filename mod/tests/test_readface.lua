-- 读面修复（F1–F4）与诊断面（READFACE）的见证用例（必须驱动真帧路径）。
-- 驱动链＝真 config ＋ 真 reload ＋ 真 source_formb ＋ 真 wiring（诊断面所在件）；只桩掉外部边界
-- （access 适配器、内存适配器、随包写面），与 test_wiring／test_logsink 同一道边界。
-- 覆盖五件事：
-- ①F1/F2 数字位字段折布尔 ⇒ 快照为布尔真且窗口能开（RC1/RC1b 回归锁：现码下必红）；
-- ②F3 块基址先解引用 avatar_manager 全局指针（条目只注册在管理器域时仍读到；RC2a 回归锁）；
-- ③F4 条目号取常量 entry（条目只注册在块内索引 10 时读到；RC2b 回归锁，并复核实际读址）；
-- ④诊断行在场且字段齐、只落一次，默认构型零行；
-- ⑤链未解析时零行、链恢复后补落一次（面非空转：行来自真实链态，不是常量）。

return function(env)
    local reload_lib = env.modules['game/reload']
    local wiring_lib = env.modules['game/wiring']
    local formb_lib = env.modules['game/source_formb']
    local config_lib = env.modules['config']

    -- 假地址布局：avatar_manager 全局指针 + 两个组件的管理器表指针 + 两张席位行 + 契约域输入块（席位 0）。
    local GAME_BASE = 0x1000000
    local AVATAR_RVA, AVATAR_MANAGER = 53636384, 0x2200000
    local MAG_MANAGER, ABILITY_MANAGER = 0x2000, 0x2100
    local MAG_TABLE, ABILITY_TABLE = 0x3000, 0x4000
    local MAG_AT, ABILITY_AT = 80, 56
    local ENTRY_SIZE, ENTRY_INDEX, HELD_AT = 32, 10, 8
    local SEAT = 0
    local BLOCK = AVATAR_MANAGER + 336 + SEAT * 686828 + 7016          -- 契约域块基址＝解引用后的管理器
    local WRONG_BLOCK = GAME_BASE + 336 + SEAT * 686828 + 7016          -- 未解引用的错址（RC2a 对照）
    local ENTRY_AT = BLOCK + ENTRY_INDEX * ENTRY_SIZE       -- 块内条目 10 的基址（＝读址，held 在基址 +HELD_AT）
    local SEAT_AT = BLOCK + SEAT * ENTRY_SIZE               -- 席位折出的条目基址（RC2b 对照）
    local WRONG_AT = WRONG_BLOCK + ENTRY_INDEX * ENTRY_SIZE -- 未解引用错址上的同号条目基址（RC2a 对照）

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

    local mem = { store = {}, seen = {} }
    function mem.available() return true end
    function mem.read(self, address, size)
        self.seen[#self.seen + 1] = address
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
    local function mem_level(base, level)
        put(base, string.rep(string.char(0), HELD_AT) .. level .. string.rep(string.char(0), ENTRY_SIZE - HELD_AT - 4))
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
    } }
    local fields = {}
    local recorder = { walked = { seat = SEAT, avatar = 4096 }, memory = mem, game = GAME_BASE,
                       chain = { avatar_manager = AVATAR_RVA } }
    function recorder.set_game(self, value) self.game = value end
    function recorder.slots() return { wield_0 = 4096 } end
    function recorder.components(self, entity) return rows end
    function recorder.fields(self, given) return fields end

    -- 随包写面的桩：契约与 bingus_write.extend 装出来的 api 同形（write_batch 是 base 优先的点调用）。
    local api = { batched = 0 }
    api.writable_data = function(base, size) return true end
    api.write_batch = function(base, size, changes)
        api.batched = api.batched + 1
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

    local function reset() said = {} end

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

    local function hex(value) return string.format('%x', value) end

    local saved_access, saved_memory = env.modules['game/access'], env.modules['game/memory']
    local saved_vendor_memory = env.modules['game/vendor/bingus_memory']
    local saved_vendor_write = env.modules['game/vendor/bingus_write']
    -- config 是整轮共享单例：授权构型会翻真总闸（wiring.new 的唯一门轴），退出时须还原，
    -- 否则后续用例的「默认构型维持假」断言看到的是前序用例留下的活值。
    local saved_instant_enabled = config_lib.instant.enabled
    local saved_capacity = config_lib.instant.capacity_default
    env.modules['game/access'] = { new = function() return recorder end }
    env.modules['game/memory'] = { new = function() return mem end }
    env.modules['game/vendor/bingus_memory'] = { new = function() return api end }
    env.modules['game/vendor/bingus_write'] = { extend = function(target) return target end }

    -- 入口的触发器引用（读闸门与 request 注入点用）。
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
        _G.print, _G.modules, _G.CowboyBingusModLoader = real_print, real_modules, real_loader
        env.modules['game/reload'] = reload_lib
        env.modules['game/access'], env.modules['game/memory'] = saved_access, saved_memory
        env.modules['game/vendor/bingus_memory'] = saved_vendor_memory
        env.modules['game/vendor/bingus_write'] = saved_vendor_write
        config_lib.instant.enabled, config_lib.instant.capacity_default = saved_instant_enabled, saved_capacity
    end

    math.randomseed(20261005)
    put(MAG_MANAGER + MAG_AT, u64(MAG_TABLE))       -- 管理器侧的数组表指针（接线件自算行地址的起点）
    put(ABILITY_MANAGER + ABILITY_AT, u64(ABILITY_TABLE))
    put(GAME_BASE + AVATAR_RVA, u64(AVATAR_MANAGER)) -- avatar_manager 全局指针（形态 B 取址的前置解引用）
    mem_set(90, 0)
    mem_running(0)
    mem_level(ENTRY_AT, HELD_DOWN)                  -- 契约域条目 10＝按下
    mem_level(SEAT_AT, HELD_UP)                     -- 席位折出的条目＝抬起（RC2b 可分辨）
    mem_level(WRONG_AT, HELD_UP)                    -- 未解引用的错址条目＝抬起（RC2a 可分辨）
    fields.reloading, fields.mag_reserve, fields.mag_ammo = 0, 90, 0
    fields.reload_stage, fields.ability_running = 0, 0
    fields.raw_wielded_by, fields.mag_chamber_round, fields.ability_id = 4096, 0, 7

    -- 一、F1/F2：真 reload ＋ 真 config 喂数字位字段 ⇒ 快照折成布尔真、窗口能开（RC1/RC1b 回归锁）。
    local authorized_system = run_entry()
    if authorized_system == nil then
        restore()
        return
    end
    env.check(trigger ~= nil, '授权构型下触发器已构造（诊断面所在件在场）')
    fields.reloading, fields.ability_running = 1, 1
    local snap = reload_lib.snapshot(trigger, 1)
    env.check(type(snap) == 'table', '数字位字段下快照可解析')
    if type(snap) == 'table' then
        env.equal(type(snap.reloading), 'boolean', '①快照的位字段一律折成布尔（消费侧口径统一）')
        env.equal(snap.reloading, true, '①reloading 为数字 1 时快照为布尔真（RC1 回归锁）')
        env.equal(snap.ability_running, true, '①ability_running 为数字 1 时快照为布尔真（RC1b 回归锁）')
        env.equal(reload_lib.window(trigger, snap), true, '①数字口径下窗口判定为真（窗口能否开＝单点）')
    end
    fields.reloading, fields.ability_running = 1, 1
    reset()
    authorized_system.frame(0.016)
    env.check(saw('WINDOW open'), '①真帧路径下窗口打开（窗口证据行在场）')

    -- 二、F3：条目只注册在解引用所得的管理器域 ⇒ 仍读到电平（RC2a 回归锁）。
    local spec = config_lib.inputs.form_b
    local formb = formb_lib.new(recorder, spec)
    local raised = formb_lib.new({ game = GAME_BASE, walked = { seat = SEAT }, memory = mem }, spec)
    env.equal(raised.level(raised), nil, '②未解引用的错址一律读不到（nil，不以 false 冒充）')
    env.equal(select(2, raised.level(raised)), 'block-unresolved', '②未解引用时如实回具名原因')
    env.equal(formb.level(formb), true, '②先解引用 avatar_manager → 管理器域条目 10 读到按下（RC2a 回归锁）')
    mem_level(ENTRY_AT, HELD_UP)
    env.equal(formb.level(formb), false, '②管理器域条目归零后电平为假（证明读数确实来自该域）')
    mem_level(ENTRY_AT, HELD_DOWN)

    -- 三、F4：条目号取常量 entry ⇒ 块内索引 10 有值、席位折出点位为零字节时仍读到（RC2b 回归锁）。
    env.equal(u32_at(SEAT_AT), 0, '③夹具自证：席位折出的条目全是零字节（退化取 seat 即读到 0）')
    mem.seen = {}
    env.equal(formb.level(formb), true, '③条目号取常量 entry（不为席位折出）→ 条目 10 读到按下')
    env.equal(mem.seen[#mem.seen], BLOCK + ENTRY_INDEX * ENTRY_SIZE, '③实际读址＝块基址 + 常量条目号*条目宽')
    -- ③b 席位只参与基址层：换席位只挪块基址，条目号与条目宽不动（flat 口径复活即落到别的地址）。
    local second_seat = 1
    local second_block = AVATAR_MANAGER + 336 + second_seat * 686828 + 7016
    local second_entry = second_block + ENTRY_INDEX * ENTRY_SIZE
    local second = formb_lib.new({ game = GAME_BASE, walked = { seat = second_seat }, memory = mem,
                                   chain = { avatar_manager = AVATAR_RVA } }, spec)
    mem_level(second_entry, HELD_DOWN)
    mem.seen = {}
    env.equal(second.level(second), true, '③换席位后同一常量条目号仍读到（条目号不随席位折出）')
    env.equal(mem.seen[#mem.seen], second_block + ENTRY_INDEX * ENTRY_SIZE,
              '③读址＝新块基址 + 常量条目号*条目宽（席位只进基址层）')

    -- 四、诊断行：授权构型落一行且字段齐、去重只落一次；默认构型零行。
    -- 用独立装配实例取行：诊断行按实例去重只落一次，前段用掉的实例不再落行。
    local face_system = run_entry()
    env.check(face_system ~= nil, '④授权构型可装配（诊断面所在件在场）')
    reset()
    if face_system ~= nil then
        face_system.frame(0.016)
        face_system.frame(0.016)
    end
    env.check(saw('READFACE '), '④授权构型落诊断行')
    env.equal(count('READFACE '), 1, '④诊断行只落一次（不刷屏）')
    env.check(saw('READFACE seat=' .. string.format('%d', SEAT)), '④诊断行带席位号')
    env.check(saw('chain=ok'), '④诊断行带链态词')
    env.check(saw('mg_domain=0x' .. hex(AVATAR_MANAGER)), '④诊断行带契约域基址（与用例独立复算一致）')
    env.check(saw('game_domain=0x' .. hex(WRONG_BLOCK)), '④诊断行带产品当前落点（RC2a 一侧）')
    env.check(saw('mg_entry10_addr=0x' .. hex(ENTRY_AT)), '④诊断行带契约域条目 10 地址')
    env.check(saw('mg_held10='), '④诊断行带契约域条目 10 采样')
    env.check(saw('prod_addr=0x' .. hex(ENTRY_AT)), '④诊断行带产品取址（条目号同口径 → 与契约域同址）')
    env.check(saw('prod_held='), '④诊断行带产品电平采样')
    env.check(saw('mute='), '④诊断行带静音位')
    env.check(api.batched == 0, '④诊断行不触发任何写入（只观测）')

    local wiring_saved = env.modules['game/wiring']
    env.modules['game/wiring'] = nil
    local default_system = run_entry()
    if default_system ~= nil then
        env.check(trigger ~= nil and trigger.request == nil, '④默认构型不注入 request')
        reset()
        default_system.frame(0.016)
        default_system.frame(0.016)
        env.check(not saw('READFACE '), '④默认构型零诊断行（诊断面只存在于授权包）')
    end
    env.modules['game/wiring'] = wiring_saved

    -- 五、非空转：链未解析时零行、链恢复后补落一次（行来自真实链态，不是常量行）。
    local kept_chain = recorder.chain
    recorder.chain = nil
    local blind_system = run_entry()
    if blind_system ~= nil then
        reset()
        blind_system.frame(0.016)
        blind_system.frame(0.016)
        env.check(not saw('READFACE '), '⑤链未解析时零诊断行（既不以 false 冒充，也不落常量行）')
        local blind = formb_lib.new(recorder, spec)
        env.equal(select(2, blind.level(blind)), 'block-unresolved', '⑤同一时刻产品侧读面也如实报 block-unresolved')
        recorder.chain = kept_chain
        blind_system.frame(0.016)
        env.check(saw('READFACE '), '⑤链恢复后补落一次诊断行（失败态不置 done）')
        env.equal(count('READFACE '), 1, '⑤补落后仍只一行')
    end
    recorder.chain = kept_chain

    restore()
end
