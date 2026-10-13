-- 「立即完成」写批次：清 ability_running（写 B，终止）＋ 弹匣两字段补弹（写 A）＋ 换弹阶段标志归零（写 C，收尾）。
-- 写集共四字段：ability_running／mag.reserve／mag.ammo／reload.stage。
-- 账目单位：mag_reserve＝弹匣计数、mag_ammo／capacity＝发数；写入与自然换弹同额——每写扣
-- 1 整匣、弹匣补满，故 ammo_new = capacity、reserve_new = reserve - 1（不再依赖开帧基数）。
-- 两条守卫：备弹不足 1 匣 ⇒ 弃本轮 reason=no-reserve；容量非测试包络（capacity ≠ 5）⇒ 弃本轮
-- reason=unsupported-profile（跨武器 reserve 单位未验，宁可弃写；不写＝让自然完成接管，优于写错账）。
--
-- 默认构建不纳入本文件（build.py 的 MODULE_ORDER／WRITE_PATH_MODULES），只在 --authorize-write 里出现，
-- 且是 mod/ 源码内唯一的写调用点。已裁纪律（逐字）：先 B 后 A、同帧同批次、禁跨帧；写前对 A、B 双快照
-- （任一读不到即弃本轮不写）；两行跨区间时按 X-1 走「同帧双调用＝等价单批次」——两次调用包在同一
-- 入口函数内、调用点连续、中间无可写路径介入，第二批失败连第一批一起回滚；每轮 1 个批次（含回滚写）、
-- 不重试；回读不符 ⇒ 回写双快照并置 voided；回滚失败 ⇒ 停写本会话 ＋ 一行 instant-abort；窗口外一律
-- REFUSE reason=window（记账不写）。窗口判据＝本帧快照推导，唯一来源；snap.window 不存在。对外：
-- instant.new(deps) -> object, reason；object:arm()；object:complete(snap) -> { status, batch,
-- rolled_back, reason, ... }；object:describe()。deps 缺任一不抛异常，只落 reason：config＝config.instant；
-- native＝config.native（字段偏移与类型只从它推）；read(address, size)->string|nil；locate(kind)->address|nil,
-- reason；batch＝已 extend 的写面，或 write_lib + api（本文件自己 extend）；log(line)。

local instant = {}

local MAG_KEY, ABILITY_KEY = 'mag', 'ability'
local RESERVE_NAME, AMMO_NAME, RUNNING_NAME = 'mag_reserve', 'mag_ammo', 'ability_running'
local STAGE_KEY, STAGE_NAME = 'reload', 'reload_stage'
local KIND_WIDTH = { u8 = 1, u32 = 4 }
local BYTE_BASE = 0x100 -- 单字节宽度：0x100 = 2^8，字节↔值的进制基
local EXPECTED_CAPACITY = 5 -- 测试包络：本武器弹匣容量（发）；非此值一律弃写（跨武器 reserve 单位未验）

local function value_of(kind, bytes)
    if type(bytes) ~= 'string' or #bytes < KIND_WIDTH[kind] then return nil end
    local out = 0
    for index = KIND_WIDTH[kind], 1, -1 do out = out * BYTE_BASE + string.byte(bytes, index) end
    return out
end
local function bytes_of(kind, value)
    local out = {}
    for index = 1, KIND_WIDTH[kind] do
        out[index] = string.char(value % BYTE_BASE)
        value = (value - value % BYTE_BASE) / BYTE_BASE
    end
    return table.concat(out)
end

local function field_spec(native, key, name) -- 偏移与宽度只从 config.native 推，不内联地址常量
    local components = type(native) == 'table' and native.components or {}
    for index = 1, #components do
        local field = components[index].key == key and components[index].arrays[1].values[name] or nil
        if field ~= nil and KIND_WIDTH[field[2]] ~= nil then
            return { offset = field[1], width = KIND_WIDTH[field[2]], kind = field[2] }
        end
    end
    return nil
end

local function read_field(self, base, field)
    return value_of(field.kind, self.read_fn(base + field.offset, field.width))
end
local function result(self, status, batch, rolled_back, reason)
    self.last = { status = status, batch = batch, rolled_back = rolled_back, reason = reason,
                  calls = self.calls, batches = self.batches,
                  reserve = self.reserve_now, ammo = self.ammo_now }
    return self.last
end

-- 唯一写入口函数（X-1 硬条件①）：写 B、写 A、写 C 背靠背、调用点连续、中间无可写路径介入；回滚同样走这里
-- （写回三行快照），故回滚写计入同一批次。返回（是否全成、write_batch 调用次数、失败串）。
local function issue(self, mag, ability, reload, running_new, reserve_new, ammo_new, stage_new)
    local running, reserve, ammo = self.layout.running, self.layout.reserve, self.layout.ammo
    local stage = self.layout.stage
    local ok_b, done_b, landed_b = pcall(self.batch, ability, running.offset + running.width,
                                         { { running.offset, bytes_of(running.kind, running_new) } })
    if not ok_b or not done_b then return false, 1, 'failed:write-b/' .. tostring(landed_b) end
    local ok_a, done_a, landed_a = pcall(self.batch, mag, ammo.offset + ammo.width,
                                         { { reserve.offset, bytes_of(reserve.kind, reserve_new) },
                                           { ammo.offset, bytes_of(ammo.kind, ammo_new) } })
    if not ok_a or not done_a then return false, 2, 'failed:write-a/' .. tostring(landed_a) end
    local ok_c, done_c, landed_c = pcall(self.batch, reload, stage.offset + stage.width,
                                         { { stage.offset, bytes_of(stage.kind, stage_new) } })
    if not ok_c or not done_c then return false, 3, 'failed:write-c/' .. tostring(landed_c) end
    return true, 3, nil
end

function instant.new(deps)
    deps = deps or {}
    local object = { config = deps.config, native = deps.native, read_fn = deps.read, batch = deps.batch,
                     locate_fn = deps.locate, log_fn = deps.log, api = deps.api, write_lib = deps.write_lib,
                     armed = false, disabled = false, calls = 0, batches = 0, layout = nil, last = nil,
                     reserve_now = nil, ammo_now = nil }
    if type(object.config) ~= 'table' then object.reason = 'no-config'
    elseif object.config.enabled ~= true then object.reason = 'disabled' end
    return setmetatable(object, { __index = instant }), object.reason
end

-- 装配期武装：缺任一依赖返回假与原因，不抛异常。
function instant.arm(self)
    if self.disabled then return false, 'write-disabled' end
    if type(self.config) ~= 'table' or self.config.enabled ~= true then return false, 'disabled' end
    if type(self.read_fn) ~= 'function' then return false, 'no-read' end
    if type(self.locate_fn) ~= 'function' then return false, 'no-locate' end
    local api, lib = self.api, self.write_lib
    if type(self.batch) ~= 'function' then
        if type(api) == 'table' and type(api.write_batch) == 'function' then self.batch = api.write_batch
        elseif type(api) == 'table' and type(lib) == 'table' and type(lib.extend) == 'function' then
            local ok, extended = pcall(lib.extend, api)
            if ok and type(extended) == 'table' then self.batch = extended.write_batch end
        end
    end
    if type(self.batch) ~= 'function' then return false, 'no-write-face' end
    if self.layout == nil then
        local reserve = field_spec(self.native, MAG_KEY, RESERVE_NAME)
        local ammo = field_spec(self.native, MAG_KEY, AMMO_NAME)
        local running = field_spec(self.native, ABILITY_KEY, RUNNING_NAME)
        local stage = field_spec(self.native, STAGE_KEY, STAGE_NAME)
        if reserve == nil or ammo == nil or running == nil or stage == nil then return false, 'layout' end
        self.layout = { reserve = reserve, ammo = ammo, running = running, stage = stage }
    end
    self.armed = true
    return true
end

-- 一轮一次：定位两行 → 双快照 → 同帧算值 → 单批次写入 → 同帧回读；返回 { status, batch, rolled_back, reason }。
-- 账目单位＝每写扣 1 整匣、弹匣补满（与自然换弹同额）；包络外容量与无备弹一律弃本轮（fail-safe，见文件头）。
function instant.complete(self, snap)
    self.calls = self.calls + 1
    self.reserve_now, self.ammo_now = nil, nil
    if self.disabled then return result(self, 'refused', nil, false, 'write-disabled') end
    if self.armed ~= true then
        self.armed, self.reason = instant.arm(self)
        if self.armed ~= true then return result(self, 'refused', nil, false, self.reason) end
    end
    if type(snap) ~= 'table' then return result(self, 'refused', nil, false, 'no-snapshot') end
    if snap.reloading ~= true or type(snap.mag_reserve) ~= 'number' or snap.mag_reserve <= 0 then
        return result(self, 'refused', nil, false, 'window')
    end
    local mag, ability, reload = self.locate_fn(MAG_KEY), self.locate_fn(ABILITY_KEY), self.locate_fn(STAGE_KEY)
    if mag == nil then return result(self, 'refused', nil, false, 'no-address:mag') end
    if ability == nil then return result(self, 'refused', nil, false, 'no-address:ability') end
    if reload == nil then return result(self, 'refused', nil, false, 'no-address:reload') end
    -- X-1 硬条件②：任何一写之前，A、B、C 三行都已完成快照
    local reserve, ammo = read_field(self, mag, self.layout.reserve), read_field(self, mag, self.layout.ammo)
    local running = read_field(self, ability, self.layout.running)
    local stage = read_field(self, reload, self.layout.stage)
    if reserve == nil or ammo == nil or running == nil or stage == nil then
        return result(self, 'refused', nil, false, 'read-failed')
    end
    -- 写入前快照值随证据行上报（零额外读面）；written 分支由回读覆盖
    self.reserve_now, self.ammo_now = reserve, ammo
    local capacity = self.config.capacity_source == 'snapshot' and snap.mag_ammo_max
                     or self.config.capacity_default
    if type(capacity) ~= 'number' then return result(self, 'refused', nil, false, 'no-capacity') end
    if capacity ~= EXPECTED_CAPACITY then
        return result(self, 'abandoned', nil, false, 'unsupported-profile')
    end
    if reserve < 1 then return result(self, 'abandoned', nil, false, 'no-reserve') end
    local ammo_new = capacity        -- 弹匣补满（与自然换弹同额：扣 1 整匣、余发不保留）
    local reserve_new = reserve - 1  -- 备弹按整匣扣减（mag_reserve 是弹匣计数，不与发数相减）
    -- 先 B 后 A 再 C：同帧、同一入口函数、不重试；无论成败都只算这一批次
    -- 写 C 的值取自然完成终态单值 0（OBSERVED stage=0 见证）；不写计时字段、不写 reloading 位（两条既有硬约束）
    local written, calls, why = issue(self, mag, ability, reload, 0, reserve_new, ammo_new, 0)
    self.batches = self.batches + 1
    local reserve_now, ammo_now
    if written == true then
        reserve_now, ammo_now = read_field(self, mag, self.layout.reserve), read_field(self, mag, self.layout.ammo)
        if reserve_now ~= nil then self.reserve_now, self.ammo_now = reserve_now, ammo_now end
    end
    if written == true and reserve_now == reserve_new and ammo_now == ammo_new then
        return result(self, 'written', calls, false, nil)
    end
    local rolled, roll_calls = issue(self, mag, ability, reload, running, reserve, ammo, stage)
    if rolled == true then return result(self, 'voided', calls + roll_calls, true,
                                         written == true and 'readback-mismatch' or why) end
    self.disabled = true
    if type(self.log_fn) == 'function' then self.log_fn(string.format('instant-abort reason=rollback-failed %s ' ..
        'reserve=%d/%d/%s ammo=%d/%d/%s', tostring(why), reserve, reserve_new, tostring(reserve_now),
        ammo, ammo_new, tostring(ammo_now))) end
    return result(self, 'aborted', calls + roll_calls, false, 'rollback-failed')
end

function instant.describe(self)
    return { enabled = type(self.config) == 'table' and self.config.enabled == true, require_window = true,
             armed = self.armed, write_disabled = self.disabled, calls = self.calls, batches = self.batches,
             capacity_default = type(self.config) == 'table' and self.config.capacity_default or nil,
             reason = self.reason, fields = self.layout, last_status = self.last and self.last.status or nil }
end

return instant
