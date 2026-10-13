-- 状态面见证：两态复现＋自检行文本＋逐键席位结果与占用计数（部分缺席态／全缺态）。
-- 覆盖两件事：
-- ①两态复现：H1（链断）与 H2（链通但 reloading 位恒 0）在状态面证据行上**同形**（WINDOW／PRESS／WRITE 全零）
--   ——即「无状态面自检行则不可归因」的机制性证明（READFACE 是输入面行、不承担该区分）；
-- ②STATEFACE 两态**可分**：H1 行带断点跳（chain=no-entity、fields=incomplete），H2 行带 fields=ok 与字段原始值。
-- 驱动链＝真 config ＋ 真 reload ＋ 真 wiring；只桩外部边界（access 适配器／内存适配器／随包写面）。

return function(env)
    local reload_lib = env.modules['game/reload']
    local config_lib = env.modules['config']

    local GAME_BASE = 0x1000000
    local AVATAR_RVA, AVATAR_MANAGER = 53636384, 0x2200000
    local MAG_MANAGER, MAG_TABLE, MAG_AT = 0x2000, 0x3000, 80
    local SEAT = 0
    local BLOCK = AVATAR_MANAGER + 336 + SEAT * 686828 + 7016
    local ENTRY_SIZE, ENTRY_INDEX, HELD_AT = 32, 10, 8
    local ENTRY_AT = BLOCK + ENTRY_INDEX * ENTRY_SIZE

    local function u32(value)
        return string.char(value % 0x100, math.floor(value / 0x100) % 0x100,
                           math.floor(value / 0x10000) % 0x100, math.floor(value / 0x1000000) % 0x100)
    end
    local function u64(value)
        local text, rest = '', value
        for _ = 1, 8 do text = text .. string.char(rest % 0x100); rest = math.floor(rest / 0x100) end
        return text
    end
    local HELD_UP, HELD_DOWN = string.char(0, 0, 0, 0), string.char(0, 0, 0x80, 0x3F)

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
            value = value + byte * scale; scale = scale * 0x100
        end
        return value
    end
    function mem.module_base(self, name) return name == 'game.dll' and GAME_BASE or nil end
    local function put(address, text) mem.store[address] = text end
    local function mem_level(base, level)
        put(base, string.rep(string.char(0), HELD_AT) .. level .. string.rep(string.char(0), ENTRY_SIZE - HELD_AT - 4))
    end

    -- 两态开关：H1＝链断（slots 回 nil，且 walked 被清空——与真适配器同语义）；H2＝链通、reloading 位恒 0。
    local state = { chain = 'H2' }
    local fields = {}
    local recorder = { memory = mem, game = GAME_BASE, chain = { avatar_manager = AVATAR_RVA }, walked = nil, holder = nil }
    -- 与真 access 适配器同形：set_game 双模（点／冒号皆可），slots／components／fields 是闭包（点调用，不收 self）。
    recorder.set_game = function(first, second) recorder.game = type(first) == 'table' and second or first end
    recorder.slots = function()
        recorder.walked, recorder.holder = nil, nil
        if state.chain == 'H1' then return nil, 'no-entity' end
        recorder.walked = { seat = SEAT, avatar = 4096, state_at = AVATAR_MANAGER + 5535792 + SEAT * 120 }
        recorder.holder = { wield_0 = 4096 }
        return recorder.holder
    end
    recorder.components = function(entity)
        if recorder.walked == nil then return nil, 'no-chain' end
        return { entity = entity, avatar = recorder.walked.avatar,
                 seats = { mag = { manager = MAG_MANAGER, index = 0,
                                   spec = { key = 'mag', arrays = { { at = MAG_AT, stride = 12 } } } } } }
    end
    recorder.fields = function(rows) return fields end

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
        for index = 1, select('#', ...) do parts[#parts + 1] = tostring(select(index, ...)) end
        said[#said + 1] = table.concat(parts, ' ')
    end
    _G.CowboyBingusModLoader = nil

    local function reset() said = {} end
    local function count(text)
        local seen = 0
        for index = 1, #said do
            if string.find(said[index], text, 1, true) ~= nil then seen = seen + 1 end
        end
        return seen
    end
    local function find_line(text)
        for index = 1, #said do
            if string.find(said[index], text, 1, true) ~= nil then return said[index] end
        end
        return nil
    end

    local saved_access, saved_memory = env.modules['game/access'], env.modules['game/memory']
    local saved_vendor_memory = env.modules['game/vendor/bingus_memory']
    local saved_vendor_write = env.modules['game/vendor/bingus_write']
    local saved_enabled, saved_capacity = config_lib.instant.enabled, config_lib.instant.capacity_default
    env.modules['game/access'] = { new = function() return recorder end }
    env.modules['game/memory'] = { new = function() return mem end }
    env.modules['game/vendor/bingus_memory'] = { new = function() return api end }
    env.modules['game/vendor/bingus_write'] = { extend = function(target) return target end }

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
        if not ok or type(system) ~= 'table' then return nil, tostring(system) end
        system.activate()
        return system
    end
    local function restore()
        _G.print, _G.modules, _G.CowboyBingusModLoader = real_print, real_modules, real_loader
        env.modules['game/reload'] = reload_lib
        env.modules['game/access'], env.modules['game/memory'] = saved_access, saved_memory
        env.modules['game/vendor/bingus_memory'] = saved_vendor_memory
        env.modules['game/vendor/bingus_write'] = saved_vendor_write
        config_lib.instant.enabled, config_lib.instant.capacity_default = saved_enabled, saved_capacity
    end

    math.randomseed(20261005)
    put(MAG_MANAGER + MAG_AT, u64(MAG_TABLE))
    put(GAME_BASE + AVATAR_RVA, u64(AVATAR_MANAGER))
    put(MAG_TABLE, u32(90))
    put(MAG_TABLE + 4, u32(0))
    mem_level(ENTRY_AT, HELD_DOWN)
    fields.reloading, fields.mag_reserve, fields.mag_ammo = 0, 90, 0
    fields.reload_stage, fields.ability_running, fields.wield_0 = 0, 0, 4096
    fields.mag_chamber_round, fields.raw_wielded_by, fields.ability_id = 0, 4096, 7

    local system = run_entry()
    if system == nil then
        env.check(false, '入口装配失败（两态复现无法进行）')
        restore()
        return
    end

    -- 态 A＝H1：链断 ⇒ 快照 nil；状态面三类行零行；STATEFACE 行带断点跳。
    state.chain = 'H1'
    reset()
    for _ = 1, 60 do system.frame(0.016) end
    local h1_snapshot_nil = (reload_lib.snapshot(trigger, 1) == nil)
    local h1_state_rows = count('WINDOW') + count('PRESS') + count('WRITE')
    local h1_line = find_line('STATEFACE')
    env.check(h1_snapshot_nil, 'H1（链断）下快照为 nil（链断成立）')
    env.equal(h1_state_rows, 0, 'H1 状态面三类行（WINDOW／PRESS／WRITE）零行')
    env.check(h1_line ~= nil, 'H1 下 STATEFACE 行在场（失败态也落行）')
    if h1_line ~= nil then
        env.check(string.find(h1_line, 'chain=no-entity', 1, true) ~= nil, '①H1 行带断点跳 chain=no-entity')
        env.check(string.find(h1_line, 'fields=incomplete', 1, true) ~= nil, '①H1 行 fields=incomplete（无字段值）')
        env.check(string.find(h1_line, 'reloading=none', 1, true) ~= nil, '①H1 行字段读不到留空（不以 0 冒充）')
    end
    env.equal(count('STATEFACE'), 1, '①H1 同因去重：同因每会话只落 1 行')

    -- 态 B＝H2：链通但 reloading 位恒 0 ⇒ 快照非 nil、窗口假；状态面三类行同样零行；STATEFACE 行带 fields=ok。
    state.chain = 'H2'
    reset()
    for _ = 1, 60 do system.frame(0.016) end
    local h2_snap = reload_lib.snapshot(trigger, 1)
    local h2_state_rows = count('WINDOW') + count('PRESS') + count('WRITE')
    local h2_line = find_line('STATEFACE')
    env.check(type(h2_snap) == 'table', 'H2（链通）下快照可解析（链通成立）')
    if type(h2_snap) == 'table' then
        env.equal(h2_snap.reloading, false, 'H2 下 reloading 折布尔为假（位恒 0）')
        env.equal(reload_lib.window(trigger, h2_snap), false, 'H2 下窗口判据为假（窗口不开）')
    end
    env.equal(h2_state_rows, 0, 'H2 状态面三类行（WINDOW／PRESS／WRITE）零行')
    env.check(h2_line ~= nil, 'H2 下 STATEFACE 行在场')
    if h2_line ~= nil then
        env.check(string.find(h2_line, 'chain=ok', 1, true) ~= nil and
                  string.find(h2_line, 'slots=ok', 1, true) ~= nil and
                  string.find(h2_line, 'comps=ok', 1, true) ~= nil, '②H2 行逐跳全 ok')
        env.check(string.find(h2_line, 'fields=ok', 1, true) ~= nil, '②H2 行 fields=ok（八字段齐）')
        env.check(string.find(h2_line, 'reloading=0', 1, true) ~= nil, '②H2 行带 reloading 原始值 0')
        env.check(string.find(h2_line, 'mag_reserve=90', 1, true) ~= nil, '②H2 行带 mag_reserve 原始值 90')
        env.check(string.find(h2_line, 'state_at=0x', 1, true) ~= nil, '②H2 行带状态行地址')
    end

    -- 机制性结论：无 STATEFACE 时两态在状态面上同形（H1 与 H2 三类行皆零）——即加自检行是必要而非可选。
    env.equal(h1_state_rows + h2_state_rows, 0, '③两态在状态面证据行上同形（均零行）——STATEFACE 是唯一区分手段')

    -- ④ 逐键容错：真 access 适配器＋合成内存（形态同 test_access 场景）走全帧路径。
    --    部分缺席态＝rounds 管理器 map 空（该席位缺席、其余四键在）⇒ comps 仍 ok、逐键行 keys=ok|absent|ok|ok|ok；
    --    全缺态＝五个组件全局缺席 ⇒ comps=map-absent、逐键行 keys=absent|absent|absent|absent|absent。
    local components, chain_spec = config_lib.native.components, config_lib.native.chain
    local function key_spec(key)
        for index = 1, #components do if components[index].key == key then return components[index] end end
    end
    local function put32(address, value) put(address, u32(value)) end
    local function put64(address, value) put(address, u64(value)) end
    local function zeros(count) return string.rep(string.char(0), count) end
    local map_at, row_base = 0x50000000, 0x70000000
    -- 管理器 map 头：+0 行数组指针、+8 容量、+12 空槽键、+16 乘数；容量取 1 ⇒ 掩码 0、键恒落 0 号槽（免哈希）。
    -- 本桩按「起始地址整段取」命中，故头部 20 字节整段写一次，再按字段偏移各写一次（lookup 头读与逐字段读两条路径都要命中）。
    local function map_slot(manager, offset, key, value)
        local rows = map_at; map_at = map_at + 0x1000
        put(manager + offset, u64(rows) .. u32(1) .. u32(0) .. u32(1))
        put(manager + offset + 8, u32(1)); put(manager + offset + 12, u32(0)); put(manager + offset + 16, u32(1))
        put(rows, key ~= nil and (u32(key) .. u32(value)) or zeros(8))
    end
    local function row(index, stride, text)
        local base = row_base; row_base = row_base + 0x1000
        put(base + index * stride, text .. zeros(stride - #text))
        return base
    end
    local GAME = GAME_BASE
    local PLAYERS, OWNER, AVATARS = 0x30000000, 0x31000000, 0x32000000
    local WIELDER, MAG, RELOAD = 0x34000000, 0x35000000, 0x36000000
    local ABILITY, WIELDABLE, ROUNDS = 0x37000000, 0x38000000, 0x39000000
    local ENTITY, WEAPON = 466, 469
    local function scene(rounds_empty, components_off)
        mem.store = {}
        map_at, row_base = 0x50000000, 0x70000000
        put64(GAME + chain_spec.player_manager, PLAYERS)
        put32(PLAYERS + chain_spec.local_unit, 0x150)
        put64(GAME + chain_spec.entity_owner, OWNER)
        put64(GAME + chain_spec.avatar_manager, AVATARS)
        map_slot(OWNER, chain_spec.owner_map, 0x150, 2)
        put(OWNER + chain_spec.owner_entities + 2 * chain_spec.entity_stride,
            zeros(chain_spec.entity_id) .. u32(ENTITY) .. zeros(chain_spec.entity_stride - chain_spec.entity_id - 4))
        map_slot(AVATARS, chain_spec.avatar_map, ENTITY, 0)
        put32(AVATARS + chain_spec.avatar_count, 1)
        put32(AVATARS + chain_spec.avatar_controller + chain_spec.identity, ENTITY)
        local state_at = AVATARS + config_lib.native.state.at
        put(state_at, zeros(config_lib.native.state.bits_at) .. string.char(0x02) ..
            zeros(40 - config_lib.native.state.bits_at - 1))
        local wielder = key_spec('wielder')
        put64(GAME + wielder.global, WIELDER)
        map_slot(WIELDER, wielder.map, ENTITY, 3)
        put64(WIELDER + wielder.arrays[1].at, row(3, wielder.arrays[1].stride, u32(WEAPON)))
        if components_off then return end
        local mag, reload = key_spec('mag'), key_spec('reload')
        local ability, wieldable, rounds = key_spec('ability'), key_spec('wieldable'), key_spec('rounds')
        put64(GAME + mag.global, MAG)
        map_slot(MAG, mag.map, WEAPON, 2)
        put64(MAG + mag.arrays[1].at, row(2, mag.arrays[1].stride, u32(4) .. u32(4)))
        put64(MAG + mag.arrays[2].at, row(2, mag.arrays[2].stride, zeros(8) .. u32(40)))
        map_slot(MAG, mag.instance.map, WEAPON, 7)
        put64(MAG + mag.instance.at, row(7, mag.instance.stride,
            zeros(136) .. u32(8) .. zeros(8) .. u32(2) .. zeros(4) .. string.char(1)))
        put64(GAME + reload.global, RELOAD)
        map_slot(RELOAD, reload.map, WEAPON, 2)
        put64(RELOAD + reload.arrays[1].at, row(2, reload.arrays[1].stride, u32(0)))
        map_slot(RELOAD, reload.instance.map, WEAPON, 3)
        put64(RELOAD + reload.instance.at, row(3, reload.instance.stride, zeros(4) .. u32(2764)))
        put64(GAME + ability.global, ABILITY)
        map_slot(ABILITY, ability.map, ENTITY, 3)
        put64(ABILITY + ability.arrays[1].at, row(3, ability.arrays[1].stride,
            u32(2764) .. zeros(4) .. u32(0x40800000) .. zeros(4) .. string.char(1) .. zeros(7) .. u32(304)))
        put64(GAME + wieldable.global, WIELDABLE)
        map_slot(WIELDABLE, wieldable.map, WEAPON, 12)
        put64(WIELDABLE + wieldable.arrays[1].at, row(12, wieldable.arrays[1].stride, u32(ENTITY)))
        put64(GAME + rounds.global, ROUNDS)
        if rounds_empty then map_slot(ROUNDS, rounds.map, nil, nil) else map_slot(ROUNDS, rounds.map, WEAPON, 5) end
    end

    env.modules['game/access'] = saved_access
    scene(true, false)
    local partial_system = run_entry()
    env.check(partial_system ~= nil, '④部分缺席态：入口装配成功')
    reset()
    for _ = 1, 60 do partial_system.frame(0.016) end
    local partial_line = find_line('STATEFACE')
    local partial_snap = reload_lib.snapshot(trigger, 1)
    env.check(partial_line ~= nil, '④部分缺席态：STATEFACE 行在场')
    if partial_line ~= nil then
        env.check(string.find(partial_line, 'chain=ok', 1, true) ~= nil and
                  string.find(partial_line, 'slots=ok', 1, true) ~= nil, '④部分缺席态：链与槽位照常')
        env.check(string.find(partial_line, 'comps=ok', 1, true) ~= nil, '④部分缺席态：单键缺席不整体失败（comps=ok）')
        env.check(string.find(partial_line, 'keys=ok|absent|ok|ok|ok', 1, true) ~= nil, '④部分缺席态：逐键席位仅 rounds 缺席')
        env.check(string.find(partial_line, 'rounds_occ=0', 1, true) ~= nil, '④部分缺席态：rounds 管理器占用计数 0（H3 信号）')
        env.check(string.find(partial_line, 'raw0=' .. tostring(WEAPON), 1, true) ~= nil, '④部分缺席态：行带槽 0 原始值')
        env.check(string.find(partial_line, 'fields=ok', 1, true) ~= nil, '④部分缺席态：REQUIRED 八字段齐（fields=ok）')
    end
    env.check(type(partial_snap) == 'table', '④部分缺席态：快照可解析（rounds 缺席不影响 REQUIRED）')
    if type(partial_snap) == 'table' then
        env.equal(partial_snap.mag_reserve, 4, '④部分缺席态：mag_reserve 原样读出')
        env.equal(partial_snap.reloading, true, '④部分缺席态：reloading 位为 1')
    end

    scene(false, true)
    local absent_system = run_entry()
    env.check(absent_system ~= nil, '④全缺态：入口装配成功')
    reset()
    for _ = 1, 60 do absent_system.frame(0.016) end
    local absent_line = find_line('STATEFACE')
    env.check(absent_line ~= nil, '④全缺态：STATEFACE 行在场')
    if absent_line ~= nil then
        env.check(string.find(absent_line, 'comps=map-absent', 1, true) ~= nil, '④全缺态：五键全缺回 map-absent')
        env.check(string.find(absent_line, 'keys=absent|absent|absent|absent|absent', 1, true) ~= nil, '④全缺态：逐键席位全缺席')
    end
    env.equal(reload_lib.snapshot(trigger, 1), nil, '④全缺态：快照为 nil（读面整体缺席）')

    -- ⑤ 写后诊断面与判据通道（新用例四类）：缓存三态／窗口期重采／拒因落行／写后快照。
    --    驱动面＝真 wiring 实例的同一套帧路径函数（track／request），只桩外部边界：
    --    instant（写面）／access（适配器）／trigger（行句柄）／log（收行）。
    local wiring_lib = env.modules['game/wiring']
    local R_GLOBAL, R_MAP, R_MANAGER, R_ROWS = 0x60000000, 40, 0x62000000, 0x63000000
    local post = { reloading = 0, reload_stage = 4, ability_running = 1, mag_ammo = 5, mag_reserve = 0, wield_0 = 4096 }
    local rows_stub = { entity = 4096, avatar = 4096, slots_raw = { 4096, 0 },
                        seats = { mag = {}, reload = {}, wieldable = {}, ability = {} } }
    local access_stub = { memory = mem, game = GAME_BASE, specs = { { key = 'rounds', global = R_GLOBAL, map = R_MAP } },
                          walked = { seat = 0, avatar = 4096, state_at = 0x4000000 } }
    function access_stub.slots() return { wield_0 = 4096 } end
    function access_stub.components(entity) return rows_stub end
    function access_stub.fields(rows) return post end
    local instant_result = nil
    local instant_stub = {}
    function instant_stub.complete(self, snap) return instant_result end
    local modules_stub = { ['game/instant'] = { new = function(deps) return {} end },
                           ['log'] = { info = function(logger, line) _G.print(line) end } }
    local cfg_stub = { instant = {}, native = config_lib.native, inputs = config_lib.inputs }
    local wire = wiring_lib.new({ modules = modules_stub, config = cfg_stub, access = access_stub,
                                  trigger = { rows = rows_stub, instant_enabled = true }, observed = {} })
    env.check(wire ~= nil and wire.gate == true, '⑤写后诊断面：真 wiring 实例装配成功（授权构型闸门开）')
    local clock = { seconds = 0, frames = 0 }
    local function tick(step)
        clock.seconds, clock.frames = clock.seconds + step, clock.frames + 1
        return clock
    end
    local snap_stub = { reloading = true }

    -- ⑤-1 缓存三态：失败带具名原因且不落缓存；未开窗不重采；开窗帧强制重采并成功。
    mem.store = {}
    reset()
    wire.track(wire, snap_stub, false, false, false, tick(0.1))
    local fail_line = find_line('STATEFACE')
    env.check(fail_line ~= nil, '⑤-1 失败态也落 STATEFACE 行')
    if fail_line ~= nil then
        env.check(string.find(fail_line, 'rounds_occ=no-manager', 1, true) ~= nil,
                  '⑤-1 管理器不可达回具名原因 no-manager（不以 none 冒充）')
    end
    env.check(wire.rounds_state ~= 'done', '⑤-1 失败不落缓存（rounds_state 非 done）')
    local face_count = count('STATEFACE')
    wire.track(wire, snap_stub, false, false, false, tick(0.1))
    env.equal(count('STATEFACE'), face_count, '⑤-1 同因去重：同键不重复落行')
    env.equal(wire.stateface_done, true, '⑤-1 全通键（ok|ok|ok|ok）后状态面停摆（场七同形：成功态只落一行）')
    put64(GAME_BASE + R_GLOBAL, R_MANAGER)
    put(R_MANAGER + R_MAP, u64(R_ROWS) .. u32(1) .. u32(0) .. u32(1))
    put(R_MANAGER + R_MAP + 8, u32(1))
    put(R_MANAGER + R_MAP + 12, u32(0))
    put(R_MANAGER + R_MAP + 16, u32(1))
    put(R_ROWS, u32(7) .. u32(0))
    wire.track(wire, snap_stub, false, false, false, tick(0.1))
    env.equal(wire.rounds_state, 'unset', '⑤-1 未开窗不重采（采样改窗口期触发）')
    wire.track(wire, snap_stub, true, false, false, tick(0.1))
    local occ_line = find_line('rounds_occ=1')
    env.check(occ_line ~= nil, '⑤-1 开窗帧强制重采：rounds 管理器占用计数得 1')
    env.equal(wire.rounds_state, 'done', '⑤-1 成功后才落缓存（三态分离）')
    env.equal(count('STATEFACE'), face_count + 1, '⑤-1 开窗帧豁免去重：同键仍落一行')
    wire.track(wire, snap_stub, true, true, false, tick(0.1))
    env.equal(count('STATEFACE'), face_count + 1, '⑤-1 重采后恢复去重（窗内不再刷行）')

    -- ⑤-2 拒因落行：窗内按压但写路径未被调用 ⇒ 次帧落 WRITE status=abandoned 行（逐项具名原因）。
    reset()
    wire.track(wire, snap_stub, true, true, true, tick(0.1))
    env.check(find_line('PRESS window ') ~= nil, '⑤-2 窗内按压落按压行')
    env.check(find_line('WRITE status=abandoned') == nil, '⑤-2 按压当帧不落拒因行（次帧才落）')
    wire.track(wire, snap_stub, true, true, false, tick(0.1))
    local gone_line = find_line('WRITE status=abandoned reason=no-hit')
    env.check(gone_line ~= nil, '⑤-2 写路径未被调用 ⇒ 次帧落 WRITE status=abandoned reason=no-hit')
    env.equal(wire.press_reason, nil, '⑤-2 拒因落行后即销账（不重复刷行）')

    -- ⑤-3 写后快照：写成功当帧 step=1、次帧 step=2 各一行，其后按帧偏移继续采样（六步）；纯诊断，零补救性写入。
    reset()
    instant_result = { status = 'written', calls = 1, reserve = 0, ammo = 5 }
    wire.instant = instant_stub
    local sent, sent_note = wiring_lib.request(wire)
    env.check(sent == true and sent_note == 'written', '⑤-3 request 交回成功（written）')
    env.check(find_line('WRITE status=written') ~= nil, '⑤-3 写面证据行在场')
    local step_one = find_line('AFTERWRITE step=1')
    env.check(step_one ~= nil, '⑤-3 写成功当帧落写后快照行（step=1）')
    if step_one ~= nil then
        env.check(string.find(step_one, 'reloading=0', 1, true) ~= nil and
                  string.find(step_one, 'reload_stage=4', 1, true) ~= nil and
                  string.find(step_one, 'ability_running=1', 1, true) ~= nil,
                  '⑤-3 快照行带 reloading 与状态机字段原始值')
    end
    wire.track(wire, snap_stub, true, true, false, tick(0.1))
    local step_two = find_line('AFTERWRITE step=2')
    env.check(step_two ~= nil, '⑤-3 写成功次帧落写后快照行（step=2）')
    env.equal(wire.after_active, true, '⑤-3 次帧后采样序列继续（步 3-6 待帧偏移／wield0 变化触发）')

    -- ⑤-4 四类行原样输出（门输出形如「case: <行文本>」，供场七判读基准引用）。
    local report = rawget(_G, '__report')
    local function emit(tag, line)
        if report ~= nil and line ~= nil then report('⑤ ' .. tag .. ' ' .. line) end
    end
    emit('缓存三态-失败具名', fail_line)
    emit('缓存三态-开窗重采', occ_line)
    emit('拒因落行', gone_line)
    emit('写后快照-step1', step_one)
    emit('写后快照-step2', step_two)

    restore()
end
