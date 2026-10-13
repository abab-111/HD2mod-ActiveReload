-- 读取面：把运行期内存读成「换弹相关字段」的只读适配器（组件全局 → 管理器 → 席位 → 行；数组行按席位、
-- 实例池按实体再查一次；通路与常量出处见实机探针读数）。依赖注入 access.new(memory,
-- config)，memory 按冒号提供 read/pointer/module_base，对外契约按点调用 slots()/components(entity)/fields(rows)
-- （set_game 两种写法都接受）。只读、绝不猜值；席位缺席三个词：no-chain / no-entity / map-absent；读不到的字段不出现。
-- 容错语义：席位缺席＝该组件字段缺席，快照层 REQUIRED 把关；单个组件席位缺席不牵连其余组件（逐键解析）。

local access = {}

local INVALID = 0xffffffff
local PTR_MIN = 0x10000
local PTR_MAX = 0x800000000000

local function u8(text, at)
    return text ~= nil and string.byte(text, at + 1) or nil
end

local function u32(text, at)
    if text == nil then return nil end
    local a, b, c, d = string.byte(text, at + 1, at + 4)
    if a == nil or b == nil or c == nil or d == nil then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- 单精度手写解码：不依赖位运算语法与 unpack
local function f32(text, at)
    local bits = u32(text, at)
    if bits == nil then return nil end
    local sign = 1
    if bits >= 0x80000000 then
        sign, bits = -1, bits - 0x80000000
    end
    local exponent = math.floor(bits / 0x800000)
    local mantissa = bits - exponent * 0x800000
    if exponent == 0 then return sign * mantissa * (2 ^ -149) end
    if exponent == 255 then return nil end
    return sign * (1 + mantissa / 0x800000) * (2 ^ (exponent - 127))
end

local function bit_and(x, mask)
    local out, place = 0, 1
    x, mask = math.floor(x), math.floor(mask)
    while mask > 0 and x > 0 do
        if mask % 2 == 1 and x % 2 == 1 then out = out + place end
        x, mask, place = math.floor(x / 2), math.floor(mask / 2), place * 2
    end
    return out
end

-- (key * mult) mod 2^32：拆 16 位半字相乘，避免 double 精度丢失
local function seed32(key, mult)
    local a0, a1 = key % 65536, math.floor(key / 65536)
    local b0, b1 = mult % 65536, math.floor(mult / 65536)
    return (a0 * b0 + ((a0 * b1 + a1 * b0) % 65536) * 65536) % 0x100000000
end

local function read_bytes(self, address, size)
    if type(address) ~= 'number' or address < PTR_MIN or address > PTR_MAX then return nil end
    if type(size) ~= 'number' or size <= 0 or address + size > PTR_MAX then return nil end
    self.reads = self.reads + 1
    local text = self.memory:read(address, size)
    if text == nil or #text < size then
        self.faults = self.faults + 1
        return nil
    end
    return text
end

local function read64(self, address)
    local text = read_bytes(self, address, 8)
    return text ~= nil and self.memory:pointer(text, 0) or nil
end

local function global_at(self, rva)
    if self.game == nil or rva == nil then return nil end
    return read64(self, self.game + rva)
end

-- 管理器 map 查找：行 8 字节（+0 键、+4 值），空槽键取 empty，走满容量即缺席
local function lookup(self, base, key)
    if base == nil or key == nil then return nil, 'absent' end
    local layout = self.layout
    local header = read_bytes(self, base, math.max(layout.capacity, layout.empty, layout.mult) + 4)
    if header == nil then return nil, 'unread' end
    local capacity, empty, mult = u32(header, layout.capacity), u32(header, layout.empty),
                                  u32(header, layout.mult)
    if capacity == nil or empty == nil or mult == nil then return nil, 'unread' end
    if capacity == 0 then return nil, 'absent' end
    local rows = self.memory:pointer(header, 0)
    if rows == nil then return nil, 'unread' end
    local mask, seed = capacity - 1, seed32(key, mult)
    for probe = 0, capacity - 1 do
        local row = read_bytes(self, rows + bit_and(seed + probe, mask) * 8, 8)
        if row == nil then return nil, 'unread' end
        local found = u32(row, 0)
        if found == key then
            local value = u32(row, 4)
            if value == nil then return nil, 'unread' end
            if value == INVALID then return nil, 'absent' end
            return value, 'present'
        end
        if found == empty then return nil, 'absent' end
    end
    return nil, 'absent'
end

local function spec_of(self, key)
    for position = 1, #self.specs do
        if self.specs[position].key == key then return self.specs[position] end
    end
    return nil
end

-- 席位：管理器全局 → 席位索引 → （backref 时）实体记录地址
local function seat_of(self, spec, entity)
    local manager = global_at(self, spec.global)
    if manager == nil then return nil, 'global' end
    local index, why = lookup(self, manager + spec.map, entity)
    if index == nil then return nil, 'map-' .. tostring(why) end
    return { manager = manager, index = index }
end

local function decode(values, text)
    local out = {}
    if text == nil then return out end
    for name, item in pairs(values) do
        local kind, at, value = item[2], item[1], nil
        if kind == 'u32' then
            value = u32(text, at)
        elseif kind == 'u8' then
            value = u8(text, at)
        elseif kind == 'f32' then
            value = f32(text, at)
        elseif kind == 'bit' then
            local byte = u8(text, at)
            value = byte ~= nil and item[3] ~= nil and math.floor(byte / (2 ^ item[3])) % 2 or nil
        end
        out[name] = value
    end
    return out
end

local function merge(target, source)
    for name, value in pairs(source) do target[name] = value end
    return target
end

-- 表基址 + 席位索引 → 行字节（table_at 为管理器内偏移）
local function row_at(self, manager, table_at, index, stride)
    local rows = read64(self, manager + table_at)
    if rows == nil then return nil end
    return read_bytes(self, rows + index * stride, stride)
end

-- 读一行并解出字段：行读不到就不解码，字段自然缺席（不拿 0 冒充）
local function read_row(self, manager, at, index, stride, values, out)
    local row = row_at(self, manager, at, index, stride)
    if row ~= nil then merge(out, decode(values, row)) end
    return row
end

-- 读第 n 个数组行（n 从 1 起），字段直接并入 out
local function read_array(self, seat, position, out)
    local array = seat.spec.arrays[position]
    return read_row(self, seat.manager, array.at, seat.index, array.stride, array.values, out)
end

-- 实例池：用实体号再查一次自己的 map，命中后按池行读字段
local function read_pool(self, seat, entity, out)
    local pool = seat.spec.instance
    if pool == nil or pool.map == nil then return nil end
    local inner = lookup(self, seat.manager + pool.map, entity)
    if inner == nil then return nil end
    return read_row(self, seat.manager, pool.at, inner, pool.stride, pool.values, out)
end

-- 玩家链：玩家管理器 → 本地单位 → entity_owner 查找 → 实体记录 → Avatar 席位 → 控制器校验
local function chain_walk(self)
    local chain = self.chain
    local players = global_at(self, chain.player_manager)
    if players == nil then return nil, 'no-chain' end
    local unit = u32(read_bytes(self, players + chain.local_unit, 4), 0)
    if unit == nil or unit == 0x7fff then return nil, 'no-chain' end
    local owner = global_at(self, chain.entity_owner)
    if owner == nil then return nil, 'no-chain' end
    local index = lookup(self, owner + chain.owner_map, unit)
    if index == nil then return nil, 'no-entity' end
    local record = read_bytes(self, owner + chain.owner_entities + index * chain.entity_stride, chain.entity_stride)
    if record == nil then return nil, 'no-entity' end
    local id = u32(record, chain.entity_id)
    if id == nil or id == 0 or id == INVALID then return nil, 'no-entity' end
    local avatars = global_at(self, chain.avatar_manager)
    if avatars == nil then return nil, 'no-entity' end
    local seat = lookup(self, avatars + chain.avatar_map, id)
    if seat == nil then return nil, 'no-entity' end
    local count = u32(read_bytes(self, avatars + chain.avatar_count, 4), 0)
    if count == nil or seat >= count then return nil, 'no-entity' end
    local controller = avatars + chain.avatar_controller + seat * chain.controller_stride
    if u32(read_bytes(self, controller + chain.identity, 4), 0) ~= id then
        return nil, 'no-entity'
    end
    return { avatar = id, seat = seat,
             state_at = avatars + self.state.at + seat * self.state.stride }
end

-- 槽位：持握组件的席位行里取两个槽的实体号（0 与无效值视为未持有）
local function slots_of(self, walked)
    local spec = spec_of(self, 'wielder')
    if spec == nil then return nil, 'map-absent' end
    local seat, why = seat_of(self, spec, walked.avatar)
    if seat == nil then return nil, why == 'global' and 'no-chain' or 'map-absent' end
    local array = spec.arrays[1]
    local row = row_at(self, seat.manager, array.at, seat.index, array.stride)
    if row == nil then return nil, 'map-absent' end
    local slots = { avatar = walked.avatar }
    for slot = 1, 2 do
        local name = slot == 1 and 'wield_0' or 'wield_1'
        local value = array.values[name] ~= nil and u32(row, array.values[name][1]) or nil
        if value ~= nil and value ~= 0 and value ~= INVALID then slots[name] = value end
    end
    if slots.wield_0 == nil and slots.wield_1 == nil then return nil, 'no-entity' end
    return slots
end

function access.new(memory, config)
    local native = (config or {}).native or {}
    local self = {
        memory = memory,
        chain = native.chain or {},
        layout = native.map or { capacity = 8, empty = 12, mult = 16 },
        specs = native.components or {},
        state = native.state or {},
        state_width = 1, -- 状态行读取宽度，下面按各值 at+4 的最大值求
        game = nil,
        reads = 0,
        faults = 0,
        walked = nil,
        holder = nil,
    }
    -- 状态行必须整行读：values 里的 at 是行内绝对偏移，不是相对 bits_at 的偏移
    for _, item in pairs(self.state.values or {}) do self.state_width = math.max(self.state_width, item[1] + 4) end
    self.set_game = function(first, second)
        self.game = type(first) == 'table' and second or first
    end
    self.slots = function()
        self.reads = 0
        self.walked, self.holder = nil, nil
        if self.game == nil then return nil, 'no-chain' end
        local walked, why = chain_walk(self)
        if walked == nil then return nil, why end
        self.walked = walked
        self.holder = slots_of(self, walked)
        -- 两槽皆空＝这一刻手里没有实体号可取，按缺席处理并把理由带上（不猜 0 号实体）
        if self.holder == nil then return nil, 'no-entity' end
        return self.holder
    end
    -- 一次解析该实体要用到的全部席位；换槽后重取即可（不做长期缓存）
    -- 逐键容错：某键席位缺席只跳过该键（seats 里留空），其余键照常解析；五键全缺才回 map-absent。
    self.components = function(entity)
        if self.walked == nil then return nil, 'no-chain' end
        local rows = { entity = entity, avatar = self.walked.avatar, seats = {} }
        local order = { 'mag', 'rounds', 'reload', 'wieldable', 'ability' }
        local found = false
        for position = 1, #order do
            local spec = spec_of(self, order[position])
            if spec ~= nil then
                local target = spec.key == 'ability' and self.walked.avatar or entity
                local seat = seat_of(self, spec, target)
                if seat ~= nil then seat.spec = spec; rows.seats[spec.key] = seat; found = true end
            end
        end
        if found ~= true then return nil, 'map-absent' end
        local wielder = spec_of(self, 'wielder')
        local array = wielder ~= nil and wielder.arrays ~= nil and wielder.arrays[1] or nil
        local values = array ~= nil and array.values or nil
        if values ~= nil and values.wield_0 ~= nil and values.wield_1 ~= nil then
            local seat = seat_of(self, wielder, self.walked.avatar)
            local row = seat ~= nil and row_at(self, seat.manager, array.at, seat.index, array.stride) or nil
            if row ~= nil then rows.slots_raw = { u32(row, values.wield_0[1]), u32(row, values.wield_1[1]) } end
        end
        return rows
    end
    -- 缺席席位守卫：nil 席位不进 read_array／read_pool（两者按 seat.spec 取址，nil 会崩）；该组字段整体缺席。
    self.fields = function(rows)
        if rows == nil or self.walked == nil then return nil, 'no-chain' end
        local out = {}
        local mag, rounds = rows.seats.mag, rows.seats.rounds
        if mag ~= nil then read_array(self, mag, 1, out); read_array(self, mag, 2, out); read_pool(self, mag, rows.entity, out) end
        local reload = rows.seats.reload
        if reload ~= nil then read_array(self, reload, 1, out); read_pool(self, reload, rows.entity, out) end
        if rows.seats.wieldable ~= nil then read_array(self, rows.seats.wieldable, 1, out) end
        if rows.seats.ability ~= nil then read_array(self, rows.seats.ability, 1, out) end
        if rounds ~= nil then read_array(self, rounds, 1, out); read_pool(self, rounds, rows.entity, out) end
        local bits = read_bytes(self, self.walked.state_at, self.state_width)
        merge(out, decode(self.state.values, bits))
        out.seat, out.avatar_id = self.walked.seat, self.walked.avatar
        local holder = self.holder or slots_of(self, self.walked)
        self.holder = holder
        if holder ~= nil then
            out.wield_0, out.wield_1 = holder.wield_0, holder.wield_1
        end
        return out
    end
    return self
end

access.invalid = INVALID

return access
