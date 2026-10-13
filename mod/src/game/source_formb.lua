-- 形态 B（默认输入源）：从 avatar 输入块的 entry_size 字节条目读 held 计数并折算成电平。
-- addr = read64(game_base + chain.avatar_manager) + base_rva + seat * avatar_stride + block_off + 条目 *
-- entry_size；条目号取常量 entry（块内物理索引），seat 只参与 base 层；'flat' 口径不采用。常量全部
-- 来自 config.inputs.form_b；读只走公开字段 access.memory:read。读不到一律 nil + reason，绝不用 0/false 冒充。

local formb = {}

-- spec 指纹用 sha256（LuaJIT 的 bit；只在装配期跑一次，不进帧路径）。无 bit ⇒ 指纹如实缺席。
local bit = type(rawget(_G, 'jit')) == 'table' and require('bit') or nil

local K = { 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 }

local function sha256(text)
    local band, bxor, rshift, lshift, ror = bit.band, bit.bxor, bit.rshift, bit.lshift, bit.ror
    local bytes = { string.byte(text, 1, #text) }
    local length = #bytes
    bytes[length + 1] = 0x80
    while #bytes % 0x40 ~= 0x38 do bytes[#bytes + 1] = 0 end
    for shift = 7, 0, -1 do bytes[#bytes + 1] = math.floor(length * 8 / 2 ^ (shift * 8)) % 0x100 end
    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local w = {}
    for at = 0, #bytes - 1, 0x40 do
        for i = 0, 0xF do
            local p = at + i * 4
            w[i + 1] = lshift(bytes[p + 1], 0x18) + lshift(bytes[p + 2], 0x10) + lshift(bytes[p + 3], 8) + bytes[p + 4]
        end
        for i = 0x11, 0x40 do
            local x, y = w[i - 0xF], w[i - 2]
            w[i] = (w[i - 0x10] + bxor(ror(x, 7), ror(x, 0x12), rshift(x, 3)) + w[i - 7] +
                    bxor(ror(y, 0x11), ror(y, 0x13), rshift(y, 0xA))) % 0x100000000
        end
        local a, b, c, d, e, f, g, k = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 1, 0x40 do
            local t1 = (k + bxor(ror(e, 6), ror(e, 0xB), ror(e, 0x19)) +
                        bxor(band(e, f), band(0xffffffff - e, g)) + K[i] + w[i]) % 0x100000000
            local t2 = (bxor(ror(a, 2), ror(a, 0xD), ror(a, 0x16)) +
                        bxor(band(a, b), band(a, c), band(b, c))) % 0x100000000
            k, g, f, e, d, c, b, a = g, f, e, (d + t1) % 0x100000000, c, b, a, (t1 + t2) % 0x100000000
        end
        h[1], h[2], h[3], h[4] = (h[1] + a) % 0x100000000, (h[2] + b) % 0x100000000, (h[3] + c) % 0x100000000, (h[4] + d) % 0x100000000
        h[5], h[6], h[7], h[8] = (h[5] + e) % 0x100000000, (h[6] + f) % 0x100000000, (h[7] + g) % 0x100000000, (h[8] + k) % 0x100000000
    end
    local hex = ''
    for i = 1, 8 do hex = hex .. string.format('%08x', h[i]) end
    return hex
end

-- spec 指纹：按固定键序拼接「键=值;」后取 sha256 前 8 位小写十六进制。
function formb.digest(spec, keys)
    if bit == nil or type(spec) ~= 'table' or type(keys) ~= 'table' then return nil, 'no-digest' end
    local text = ''
    for position = 1, #keys do
        local key = keys[position]
        text = text .. key .. '=' .. tostring(spec[key]) .. ';'
    end
    return string.sub(sha256(text), 1, 8), nil
end

-- 手写单精度解码（照 access.lua 同款做法，不依赖 string.unpack）；NaN / Inf 如实产出并标注。
local function f32(text, at)
    local a, b, c, d = string.byte(text, at + 1, at + 4)
    if a == nil then return nil, 'short' end
    local bits = a + b * 0x100 + c * 0x10000 + d * 0x1000000
    local sign, value = 1, bits
    if bits >= 0x80000000 then sign, value = -1, bits - 0x80000000 end
    local exponent = math.floor(value / 0x800000)
    local mantissa = value % 0x800000
    if exponent == 0 then return sign * mantissa * (2 ^ -0x95), 'subnormal' end
    if exponent == 0xFF then
        if mantissa == 0 then return sign * math.huge, 'inf' end
        return 0 / 0, 'nan'
    end
    return sign * (1 + mantissa / 0x800000) * (2 ^ (exponent - 0x7F)), 'normal'
end

-- 块基址（不含条目索引）：先解引用 avatar_manager 全局指针（研究侧同款解引用，见 arc/src/config.lua）再叠加偏移，任一环不成立即 block-unresolved。
local function block(self, spec)
    local access = self.access
    local seat = access.walked ~= nil and access.walked.seat or nil
    local rva = access.chain ~= nil and access.chain.avatar_manager or nil
    local text = type(rva) == 'number' and type(access.game) == 'number' and access.memory:read(access.game + rva, 8) or nil
    local manager = type(text) == 'string' and #text >= 8 and access.memory:pointer(text, 0) or nil
    if type(seat) ~= 'number' or type(manager) ~= 'number' or manager == 0 then return nil, 'block-unresolved' end
    return manager + spec.base_rva + seat * spec.avatar_stride + spec.block_off
end

-- 条目一次读足 entry_size 字节；宽度不足以容纳 held_at + 4 一律 read-failed，不少读 1 字节凑数。
local function read_entry(self, index)
    local spec = self.spec
    local width = spec.entry_size
    if type(width) ~= 'number' or width < spec.held_at + 4 then return nil, 'read-failed' end
    local address = block(self, spec)
    if address == nil then return nil, 'block-unresolved' end
    local text = self.access.memory:read(address + index * width, width)
    self.reads = self.reads + 1
    if text == nil or #text < width then
        self.faults = self.faults + 1
        return nil, 'read-failed'
    end
    local held, note = f32(text, spec.held_at)
    self.note = note
    return held
end

-- 电平读数：held ~= hold_epsilon 即按下（默认 0.0 ⇒ 严格非零）。读不到一律 nil + reason（H3），
-- 绝不以 false 冒充；「静音」与「读不到」是两件事，静音时 mute 为真且 level 回 false。
function formb.level(self)
    local spec = self.spec
    local seat = self.access.walked ~= nil and self.access.walked.seat or nil
    if type(seat) ~= 'number' or type(self.access.game) ~= 'number' then return nil, 'block-unresolved' end
    if type(spec.hold_epsilon) ~= 'number' or type(spec.entry) ~= 'number' then return nil, 'spec-incomplete' end
    local index = spec.entry   -- 条目号＝常量 entry（块内物理索引，行为判定所得）；seat 只参与 base 层
    local held, why = self.read_held(index)
    if held == nil then return nil, why or 'read-failed' end
    self.mute = held == spec.hold_epsilon
    return held ~= spec.hold_epsilon
end

-- 装配：缺 access / spec 一律 nil + reason（不抛异常）；实例经 __index 取 level 等面。
function formb.new(access, spec)
    if type(access) ~= 'table' or type(access.memory) ~= 'table' then return nil, 'no-access' end
    if type(spec) ~= 'table' then return nil, 'no-spec' end
    local out = setmetatable({ name = 'form_b', access = access, spec = spec, reads = 0, faults = 0,
                               mute = false, note = nil }, { __index = formb })
    out.read_held = function(index) return read_entry(out, index) end  -- 装配期绑定，帧路径零分配
    return out
end

-- 只读快照：「静音」与「读数链是否正常」分列，不含糊其辞（断言比对对象）。
function formb.describe(self)
    local spec = self.spec
    local out = { name = 'form_b', source = 'game/source_formb' }
    out.index_map, out.entry_size, out.held_at = spec.index_map, spec.entry_size, spec.held_at
    out.held_kind, out.hold_epsilon = spec.held_kind, spec.hold_epsilon
    out.mute_windows, out.reads, out.faults = spec.mute_windows, self.reads, self.faults
    out.mute, out.note = self.mute, self.note
    return out
end

-- 复位：只清内部计数与标注；换 spec 由调用方显式传入，不重取件。
function formb.reset(self, spec)
    if type(spec) == 'table' and type(spec.base_rva) == 'number' then self.spec = spec end
    self.reads, self.faults, self.mute, self.note = 0, 0, false, nil
end

return formb
