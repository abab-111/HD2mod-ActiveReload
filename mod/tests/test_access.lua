-- 读取面：合成内存全路径驱动——玩家链、席位查找、数组行与实例池字段、三态缺席、预算计数。
-- 合成数据的每一处取值都标注出处（实机探针读数的实证值），保证「假数据有真出处」；
-- 地址布局是为了让查找路径可走通而构造的，不声称与实机地址相同。

return function(env)
    local access_lib = env.modules['game/access']
    local config = env.modules['config']

    local function bit_and(x, mask)
        local out, place = 0, 1
        x, mask = math.floor(x), math.floor(mask)
        while mask > 0 and x > 0 do
            if mask % 2 == 1 and x % 2 == 1 then out = out + place end
            x, mask, place = math.floor(x / 2), math.floor(mask / 2), place * 2
        end
        return out
    end

    local function seed32(key, mult)
        local a0, a1 = key % 65536, math.floor(key / 65536)
        local b0, b1 = mult % 65536, math.floor(mult / 65536)
        return (a0 * b0 + ((a0 * b1 + a1 * b0) % 65536) * 65536) % 0x100000000
    end

    local function make_memory()
        local self = { bytes = {}, mapped = {} }
        function self.cover(address, size)
            for offset = 0, size - 1 do
                if self.bytes[address + offset] == nil then self.bytes[address + offset] = 0 end
            end
        end
        function self.put8(address, value)
            self.bytes[address] = value % 256
        end
        function self.put32(address, value)
            for offset = 0, 3 do
                self.put8(address + offset, math.floor(value / (256 ^ offset)))
            end
        end
        function self.put64(address, value)
            self.put32(address, value % 0x100000000)
            self.put32(address + 4, math.floor(value / 0x100000000))
        end
        -- 冒号与点两种调用都接受：产品适配器按冒号约定调用，测试内部用点。
        function self.read(first, second, third)
            local address, size = first, second
            if type(first) == 'table' then address, size = second, third end
            if type(address) ~= 'number' or type(size) ~= 'number' then return nil end
            local parts = {}
            for offset = 0, size - 1 do
                local byte = self.bytes[address + offset]
                if byte == nil then return nil end
                parts[#parts + 1] = string.char(byte)
            end
            return table.concat(parts)
        end
        function self.pointer(first, second)
            local text = type(first) == 'table' and second or first
            if type(text) ~= 'string' then return nil end
            local value = 0
            for offset = 0, 7 do
                local byte = string.byte(text, offset + 1)
                if byte == nil then return nil end
                value = value + byte * (256 ^ offset)
            end
            return value
        end
        return self
    end

    -- 管理器 map：头在 manager+offset（+0 行数组指针、+8 容量、+12 空槽键、+16 乘数）；
    -- 行数组按 offset 各占一段，避免同一管理器下多个 map 的行数组互相覆盖。
    local function set_map(memory, manager, offset, key, value, capacity, mult)
        local rows = manager + 0x2000 + offset * 0x100
        memory.cover(rows, capacity * 8)
        memory.put64(manager + offset, rows)
        memory.put32(manager + offset + 8, capacity)
        memory.put32(manager + offset + 12, 0)
        memory.put32(manager + offset + 16, mult)
        local slot = bit_and(seed32(key, mult), capacity - 1)
        memory.put32(rows + slot * 8, key)
        memory.put32(rows + slot * 8 + 4, value)
        return slot
    end

    local GAME = 0x1000000
    local PLAYERS, OWNER, AVATARS = 0x2000000, 0x3000000, 0x4000000
    local WIELDER, MAG, RELOAD = 0x5000000, 0x9000000, 0xD000000
    local ABILITY, WIELDABLE, ROUNDS = 0x10000000, 0x12000000, 0x14000000

    local chain = config.native.chain
    local components = config.native.components

    local function spec(key)
        for index = 1, #components do
            if components[index].key == key then return components[index] end
        end
    end

    -- 合成场景：实体号 466 为本地玩家（席位 0），手持武器实体 469（席位 2）。
    -- 逐组取值出处（实机探针读数）：
    --   玩家链（unit 0x150→owner_index 405→实体 466）与 map 头形态（+0 行数组指针/+8 容量/+12 空槽键/+16 乘数）＝「玩家链」「组件管理器」行；
    --   avatar 席位 0 与控制器 +2948 identity=466 ＝玩家链行（`seat=0 controller=… identity=true`）；
    --   wielder 席位 85、wield_0@0=469 / wield_1@80 空（数组步长 464）＝「行解码」L1312/L1314 与 T2（`wield_1=none`）；
    --   mag arrays[1] at=80 stride=12 reserve=4 ammo=4、arrays[2] at=72 stride=16 chamber_round=40 ＝「字段值」L1315/L1316；
    --   reload arrays[1] at=80 stride=4 reload_stage=0、实例池 reload_ability=2764 ＝ L1319 与 T3 段 A/B；
    --   wieldable at=56 stride=4 =466 ＝ L1321（与 raw_wielded_by=466 互证同一持握者）；
    --   ability 席位 85、id=2764、time=4.0、running=1 ＝ T1 同帧同步三路（段 A 终值 4.689）；
    --   **合成占位**（实机未观测到值，只证读取路径能读，不证实机值）：mag 实例池 ammo_max/spare_capacity/chambered ＝ T4 未命中项（83/83 采样 nil、探针自报 `miss3`）；rounds 全组 ＝ T4 `no-spec`/`map-absent`。
    local function scene()
        local memory = make_memory()
        memory.put64(GAME + chain.player_manager, PLAYERS)
        memory.put32(PLAYERS + chain.local_unit, 0x150)          -- 本地单位号
        memory.put64(GAME + chain.entity_owner, OWNER)
        memory.put64(GAME + chain.avatar_manager, AVATARS)
        -- 玩家链：单位 0x150 → 席位 405 → 实体记录（记录就地存放，其中 +8 为实体号 466）
        local record_at = OWNER + chain.owner_entities + 405 * chain.entity_stride
        memory.cover(record_at, chain.entity_stride)
        memory.put32(record_at + chain.entity_id, 466)
        set_map(memory, OWNER, chain.owner_map, 0x150, 405, 4, 2)
        set_map(memory, AVATARS, chain.avatar_map, 466, 0, 4, 2)
        memory.put32(AVATARS + chain.avatar_count, 1)
        memory.put32(AVATARS + chain.avatar_controller + chain.identity, 466)
        local state_at = AVATARS + config.native.state.at
        memory.cover(state_at, config.native.state.stride)          -- 状态行整行在（读取面按行读）
        memory.put8(state_at + config.native.state.bits_at, 0x02)   -- 状态位：reloading 置位
        -- 持握组件：席位 85 的行里 wield_0=469、wield_1 未持有
        memory.put64(GAME + spec('wielder').global, WIELDER)
        memory.put64(WIELDER + spec('wielder').backref, 0x6000000)
        memory.cover(0x6000000 + 405 * 8, 8)
        memory.put64(0x6000000 + 405 * 8, 0x7000000)
        memory.put64(WIELDER + spec('wielder').arrays[1].at, 0x8000000)
        memory.cover(0x8000000 + 85 * 464, 464)
        memory.put32(0x8000000 + 85 * 464 + 0, 469)
        memory.put32(0x8000000 + 85 * 464 + 80, 0)
        set_map(memory, WIELDER, spec('wielder').map, 466, 85, 4, 2)
        -- 弹匣组件：数组[1] reserve=4 ammo=4；数组[2] chamber_round=40；实例池 ammo_max=8 spare=2 chambered=1
        memory.put64(GAME + spec('mag').global, MAG)
        memory.put64(MAG + spec('mag').instance.at, 0xC000000)
        memory.put64(MAG + spec('mag').arrays[1].at, 0xA000000)
        memory.put64(MAG + spec('mag').arrays[2].at, 0xB000000)
        memory.cover(0xA000000 + 2 * 12, 12)
        memory.put32(0xA000000 + 2 * 12 + 0, 4)
        memory.put32(0xA000000 + 2 * 12 + 4, 4)
        memory.cover(0xB000000 + 2 * 16, 16)
        memory.put32(0xB000000 + 2 * 16 + 8, 40)
        memory.cover(0xC000000 + 7 * 160, 160)
        memory.put32(0xC000000 + 7 * 160 + 136, 8)
        memory.put32(0xC000000 + 7 * 160 + 148, 2)
        memory.put8(0xC000000 + 7 * 160 + 156, 1)
        set_map(memory, MAG, spec('mag').map, 469, 2, 4, 2)
        set_map(memory, MAG, spec('mag').instance.map, 469, 7, 4, 2)
        -- 换弹组件：reload_stage=0；实例池 reload_ability=2764
        memory.put64(GAME + spec('reload').global, RELOAD)
        memory.put64(RELOAD + spec('reload').arrays[1].at, 0xE000000)
        memory.put64(RELOAD + spec('reload').instance.at, 0xF000000)
        memory.cover(0xE000000 + 2 * 4, 4)
        memory.put32(0xE000000 + 2 * 4, 0)
        memory.cover(0xF000000 + 3 * 80, 80)
        memory.put32(0xF000000 + 3 * 80 + 4, 2764)
        set_map(memory, RELOAD, spec('reload').map, 469, 2, 4, 2)
        set_map(memory, RELOAD, spec('reload').instance.map, 469, 3, 4, 2)
        -- 能力组件（挂在玩家实体 466 上）：id=2764、time=4.0s、running=1、事件数=304
        memory.put64(GAME + spec('ability').global, ABILITY)
        memory.put64(ABILITY + spec('ability').arrays[1].at, 0x11000000)
        memory.cover(0x11000000 + 85 * 224, 224)
        memory.put32(0x11000000 + 85 * 224 + 0, 2764)
        memory.put32(0x11000000 + 85 * 224 + 8, 0x40800000)      -- 单精度 4.0
        memory.put8(0x11000000 + 85 * 224 + 16, 1)
        memory.put32(0x11000000 + 85 * 224 + 24, 304)
        set_map(memory, ABILITY, spec('ability').map, 466, 85, 4, 2)
        -- 可持握组件：raw_wielded_by=466（与手持实体 469 互证同一持握者）
        memory.put64(GAME + spec('wieldable').global, WIELDABLE)
        memory.put64(WIELDABLE + spec('wieldable').arrays[1].at, 0x13000000)
        memory.cover(0x13000000 + 12 * 4, 4)
        memory.put32(0x13000000 + 12 * 4, 466)
        set_map(memory, WIELDABLE, spec('wieldable').map, 469, 12, 4, 2)
        -- 弹丸组件：rounds_0=4、rounds_1=0；实例池容量 4.0、备用 2、腔室 1
        memory.put64(GAME + spec('rounds').global, ROUNDS)
        memory.put64(ROUNDS + spec('rounds').arrays[1].at, 0x15000000)
        memory.put64(ROUNDS + spec('rounds').instance.at, 0x16000000)
        memory.cover(0x15000000 + 2 * 20, 20)
        memory.put32(0x15000000 + 2 * 20 + 8, 4)
        memory.put32(0x15000000 + 2 * 20 + 12, 0)
        memory.cover(0x16000000 + 5 * 136, 136)
        memory.put32(0x16000000 + 5 * 136 + 72, 0x40800000)     -- 容量 4.0
        memory.put32(0x16000000 + 5 * 136 + 80, 2)
        memory.put8(0x16000000 + 5 * 136 + 104, 1)
        set_map(memory, ROUNDS, spec('rounds').map, 469, 2, 4, 2)
        set_map(memory, ROUNDS, spec('rounds').instance.map, 469, 5, 4, 2)
        return memory
    end

    local function reader(memory)
        local unit = access_lib.new(memory, config)
        unit:set_game(GAME)
        return unit
    end

    -- ① 链与槽位：wield_0=469（一号位），wield_1 未持有
    local memory = scene()
    local unit = reader(memory)
    env.check(unit.game == GAME, '模块基址已设置（实际 ' .. tostring(unit.game) .. '）')
    local slots, why = unit.slots()
    env.equal(type(slots), 'table', '玩家链解析成功（原因 ' .. tostring(why) .. '）')
    env.equal(slots.wield_0, 469, '一号位实体号')
    env.equal(slots.wield_1, nil, '二号位未持有')
    env.equal(slots.avatar, 466, '本地玩家实体号')

    -- ② 席位与字段：数组行 + 实例池一次读全
    local rows, rows_why = unit.components(469)
    env.equal(type(rows), 'table', '组件席位解析成功（' .. tostring(rows_why) .. '）')
    local before = unit.reads
    local fields, fields_why = unit.fields(rows)
    env.equal(type(fields), 'table', '字段读取成功（' .. tostring(fields_why) .. '）')
    env.equal(fields.mag_reserve, 4, '弹匣备用弹数')
    env.equal(fields.mag_ammo, 4, '弹匣当前弹数')
    env.equal(fields.mag_chamber_round, 40, '腔室读数')
    env.equal(fields.mag_ammo_max, 8, '实例池上限字段')
    env.equal(fields.mag_spare_capacity, 2, '实例池备弹容量')
    env.equal(fields.mag_chambered, 1, '实例池已上膛位')
    env.equal(fields.reload_stage, 0, '换弹阶段')
    env.equal(fields.reload_ability, 2764, '换弹能力编号')
    env.equal(fields.rounds_0, 4, '弹丸组一号计数')
    env.near(fields.capacity_0, 4.0, 1e-6, '弹丸组容量')
    env.equal(fields.raw_wielded_by, 466, '持握者与手持实体互证')
    env.equal(fields.ability_id, 2764, '能力编号（取自玩家实体）')
    env.equal(fields.ability_running, 1, '能力运行位')
    env.near(fields.ability_time, 4.0, 1e-6, '能力计时辅助量')
    env.equal(fields.action_events, 304, '能力事件计数')
    env.equal(fields.reloading, 1, '状态位折出换弹中')
    env.equal(fields.seat, 0, '本地玩家席位')
    env.equal(fields.avatar_id, 466, '状态面用到的玩家实体号')

    -- ③ 预算：字段面一帧 = 6 数组行×（取行数组指针 1 + 读行 1）+ 3 实例池×（查席位 2（表头 + 探槽行）+ 读行 2）+ 状态行 1
    --     ＝25 次物理读，对应方案的「12 次行内字段读 + ≤3 次实例池读」；不随容量线性放大
    env.check(unit.reads - before <= 25, '字段读取次数在预算内（实际 ' .. tostring(unit.reads - before) .. '）')

    -- ④ 三态缺席：链未就绪、席位查不到、槽未持有
    local blank = access_lib.new(memory, config)
    local no_slots, no_chain = blank.slots()
    env.equal(no_slots, nil, '未取到模块基址时不给槽位')
    env.equal(no_chain, 'no-chain', '未就绪报 no-chain')
    memory.put32(MAG + spec('mag').map + 8, 0)                   -- 容量清零 ⇒ 该键席位缺席
    local partial, partial_why = unit.components(469)
    env.equal(partial_why, nil, '单键席位缺席不整体回 nil（逐键容错）')
    env.check(type(partial) == 'table' and partial.seats.mag == nil, '缺席键在 seats 里留空')
    env.check(type(partial) == 'table' and partial.seats.rounds ~= nil, '其余键照常解析（rounds 在）')
    memory.put32(MAG + spec('mag').map + 8, 4)
    memory.put32(0x8000000 + 85 * 464 + 0, 0)                    -- 两个槽都空
    local empty_slots, empty_why = unit.slots()
    env.equal(empty_slots, nil, '两槽皆空时不给槽位')
    env.equal(empty_why, 'no-entity', '报 no-entity')
    memory.put32(0x8000000 + 85 * 464 + 0, 469)

    -- ⑤ 席位硬校验：控制器身份不符即判实体不存在（不拿错实体的数据）
    memory.put32(AVATARS + chain.avatar_controller + chain.identity, 999)
    local bad_slots, bad_why = unit.slots()
    env.equal(bad_slots, nil, '身份校验不符时不给槽位')
    env.equal(bad_why, 'no-entity', '报 no-entity')
    memory.put32(AVATARS + chain.avatar_controller + chain.identity, 466)

    -- ⑥ 换槽后重取席位：同一实体号换新武器 ⇒ 席位索引随新实体走
    memory.put32(0x8000000 + 85 * 464 + 0, 512)
    set_map(memory, MAG, spec('mag').map, 512, 3, 4, 2)
    set_map(memory, ROUNDS, spec('rounds').map, 512, 3, 4, 2)
    set_map(memory, RELOAD, spec('reload').map, 512, 3, 4, 2)
    set_map(memory, WIELDABLE, spec('wieldable').map, 512, 3, 4, 2)
    local slots2 = unit.slots()
    env.equal(slots2.wield_0, 512, '换槽后槽实体更新')
    local rows2 = unit.components(512)
    env.equal(rows2.seats.mag.index, 3, '换槽后席位索引随新实体')

    -- ⑦ 状态位翻转：清位后同一帧读到未换弹
    memory.put8(AVATARS + config.native.state.at + config.native.state.bits_at, 0x00)
    local fields2 = unit.fields(rows2)
    env.equal(fields2.reloading, 0, '状态位清零后读到未换弹')

    -- ⑧ 读面交接：读句柄按公开字段挂在对象上，外部模块（形态 B）由此读内存；
    --    反向断言：模块表上不导出 read_bytes（那是文件内局部函数，不是对外面），
    --    免得下游绕开公开字段、直接摸到内部实现。
    local handed = access_lib.new(memory, config)
    env.check(handed.memory == memory, '读句柄为公开字段且与注入的读取面同一对象')
    env.equal(type(handed.memory.read), 'function', '公开字段上可直接调用 read')
    env.equal(type(access_lib.read_bytes), 'nil', '模块表不导出 read_bytes')
end
