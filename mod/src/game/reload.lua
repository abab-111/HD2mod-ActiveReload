-- 重装通道：写路径注入点（原样保留）+ 只读状态面（叠加，不改既有签名）。
--
-- 叠加原则：新形参缺省 nil 时，send 的行为与接线前**逐字相同**（false, 'unavailable'），
-- 因此未接线的装配不会改变任何既有表现，随时可回滚。
--
-- 读取面 access（由调用方注入，nil 时所有读接口返回 nil 与原因）：
--   access.now()               -> number|nil           游戏侧时钟（秒）
--   access.slots()             -> table|nil, reason    { wield_0 = 实体号, wield_1 = 实体号 }，每帧重查
--   access.components(entity)  -> table|nil, reason    该实体下挂组件的行句柄；换槽或映射重建后重取
--   access.fields(rows)        -> table|nil, reason    按行句柄读字段；**读不到的字段不出现**
--
-- 三条纪律（读侧）：
--   1. 槽实体不缓存复用：持握槽变化时重查该槽实体并重取组件行；
--   2. 组件标签读不到不得当成数值 0：清缓存、下一帧重走链，并把原因原样上报；
--   3. 读失败一律 nil 与原因，绝不用 0 / false / 空表冒充读数。

local reload = {}

-- 每帧必读的字段（缺任一 ⇒ 本帧快照作废并报出缺哪个）；其余字段允许缺席。
local REQUIRED = { 'reloading', 'raw_wielded_by', 'mag_ammo', 'mag_reserve', 'mag_chamber_round',
                   'reload_stage', 'ability_id', 'ability_running' }

function reload.new(request, access)
    return {
        request = request,
        access = access,
        rows = nil,
        slot = nil,
        rebuilt = 0,
        frame = nil,
        snap = nil,
        previous = nil,
        started = nil,
        baseline = nil,
    }
end

-- 装配后再注入或替换读取面（读取面就绪晚于模块加载时使用）
function reload.bind(self, access)
    self.access = access
    return reload.reset(self)
end

-- 清空链缓存：下一次快照会重新取槽与组件行。换槽、映射重建、显式重置都走这里。
function reload.reset(self)
    if self.rows ~= nil or self.slot ~= nil then
        self.rebuilt = self.rebuilt + 1
    end
    self.rows, self.slot, self.frame, self.snap = nil, nil, nil, nil
    return true
end

local function first_missing(fields, names)
    for position = 1, #names do
        local name = names[position]
        if fields[name] == nil then
            return name
        end
    end
    return nil
end

-- 一帧一次：解析当前持握槽 → 取组件行 → 读字段。同一帧重复调用返回同一份快照，不重复读。
function reload.snapshot(self, frame)
    if self.access == nil then
        return nil, 'unavailable'
    end
    if self.snap ~= nil and frame ~= nil and self.frame == frame then
        return self.snap
    end
    local slots, why = self.access.slots()
    if slots == nil then
        return nil, why or 'no-entity'
    end
    local entity, index = slots.wield_0, 1
    if entity == nil then
        entity, index = slots.wield_1, 2
    end
    if entity == nil then
        return nil, 'no-entity'
    end
    if self.rows == nil or self.slot ~= entity then
        local rows, note = self.access.components(entity)
        if rows == nil then
            return nil, note or 'map-absent'
        end
        self.rows, self.slot = rows, entity
        self.rebuilt = self.rebuilt + 1
    end
    local fields, note = self.access.fields(self.rows)
    if fields == nil then
        reload.reset(self)
        return nil, note or 'map-absent'
    end
    local absent = first_missing(fields, REQUIRED)
    if absent ~= nil then
        return nil, 'missing:' .. absent
    end
    local snap = {
        slot_index = index,
        weapon_entity = entity,
        seat = fields.seat,
        avatar_id = fields.avatar_id,
        time = self.access.now ~= nil and self.access.now() or nil,
        reloading = fields.reloading == 1,   -- 位字段是数字 0/1（与 probe/arc 解码同口径），比较侧统一折成布尔
        reload_stage = fields.reload_stage,
        mag_reserve = fields.mag_reserve,
        mag_ammo = fields.mag_ammo,
        mag_chamber_round = fields.mag_chamber_round,
        mag_ammo_max = fields.mag_ammo_max,
        mag_spare_capacity = fields.mag_spare_capacity,
        mag_chambered = fields.mag_chambered,
        rounds_0 = fields.rounds_0,
        rounds_1 = fields.rounds_1,
        capacity_0 = fields.capacity_0,
        capacity_1 = fields.capacity_1,
        raw_wielded_by = fields.raw_wielded_by,
        reload_ability = fields.reload_ability,
        ability_id = fields.ability_id,
        ability_running = fields.ability_running == 1, -- 同上：数字位字段折成布尔（观测面按布尔消费）
        ability_time = fields.ability_time,
        action_events = fields.action_events,
    }
    self.frame, self.snap = frame, snap
    return snap
end

-- 换弹起止沿：只读传入的快照，不访问内存（可离线用固定快照做用例）
function reload.edge(self, snap)
    if snap == nil then
        return nil, 'no-snapshot'
    end
    local now, was = snap.reloading, self.previous
    self.previous = now
    if was == nil then
        return nil, 'first-frame'
    end
    if now and not was then
        self.started = snap.time
        return 'start'
    end
    if was and not now then
        if self.started ~= nil and snap.time ~= nil then
            self.baseline = snap.time - self.started
        end
        return 'end'
    end
    return nil
end

-- 本次换弹总时长（按错惩罚的基线）：未结束时报 pending，结束后给实测秒数
function reload.duration(self, snap)
    if snap == nil then
        return nil, 'no-snapshot'
    end
    if snap.reloading then
        return nil, 'pending'
    end
    if self.baseline ~= nil then
        return self.baseline
    end
    if self.started ~= nil and snap.time ~= nil then
        return snap.time - self.started
    end
    return nil, 'no-baseline'
end

-- 「满弹且可开火」判定输入：弹匣或腔室还有弹即为可开火；两处都读不到时报缺失
function reload.ready_to_fire(self, snap)
    if snap == nil then
        return nil, 'no-snapshot'
    end
    if snap.mag_ammo == nil and snap.mag_chamber_round == nil then
        return nil, 'missing:mag_ammo'
    end
    if snap.reloading ~= true then
        return false, 'not-reloading'
    end
    local loaded = (snap.mag_ammo or 0) + (snap.mag_chamber_round or 0)
    if loaded <= 0 then
        return false, 'empty'
    end
    return true
end

-- 窗口门：只读传入的快照，不访问内存。窗口 = 换弹标志为真且弹匣余弹为正的连续帧段（含两端帧）。
-- 快照缺失与字段读不到是两种不同的失败（nil ＋ 具名 reason），绝不用 false 冒充。
function reload.window(self, snap)
    if snap == nil then return nil, 'no-snapshot' end
    if snap.reloading ~= true then return false, 'not-reloading' end
    if snap.mag_reserve == nil then return nil, 'read-failed' end
    if snap.mag_reserve <= 0 then return false, 'empty-reserve' end
    return true
end

-- 写路径：签名不动；失败语义只多一个 'disabled'（显式关闭时），其余分支与接线前逐字相同
function reload.send(self)
    -- 总闸由接线方注入 config.instant.enabled；nil（未接线）不改变任何既有行为
    if self.instant_enabled == false then
        return false, 'disabled'
    end
    if type(self.request) ~= 'function' then
        return false, 'unavailable'
    end
    local ok = self.request()
    if ok == nil then
        return false, 'unavailable'
    end
    return ok == true, 'reported'
end

return reload
