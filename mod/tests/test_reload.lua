-- 只读状态面：未注入读取面时的降级、同帧缓存、缺字段如实报错、换槽重取组件行、
-- 映射失效后的重建、起止沿与时长、可开火判定、写路径签名不变。

return function(env)
    local reload = env.modules['game/reload']

    -- extra 覆盖取值，omit 显式抹掉字段（用于构造「读不到」的帧）
    local function fields(extra, omit)
        local base = {
            reloading = 0, raw_wielded_by = 466, mag_reserve = 4, mag_ammo = 4,
            mag_chamber_round = 40, reload_stage = 0, ability_id = 2764,
            ability_running = 0, seat = 0, avatar_id = 466,
        }
        for key, value in pairs(extra or {}) do
            base[key] = value
        end
        for position = 1, #(omit or {}) do
            base[omit[position]] = nil
        end
        return base
    end

    -- ① 未注入读取面：读接口一律 nil 与原因，写路径签名与失败语义不变
    local idle = reload.new(nil)
    local snap, why = reload.snapshot(idle, 1)
    env.equal(snap, nil, '未注入读取面时快照为空')
    env.equal(why, 'unavailable', '未注入读取面时报 unavailable')
    env.equal(reload.duration(idle, { reloading = false }), nil, '无基线时时长为空')
    local sent, note = reload.send(idle)
    env.equal(sent, false, '写路径未注入时仍返回 false')
    env.equal(note, 'unavailable', '写路径未注入时仍报 unavailable')

    -- ② 读取面替身：逐帧脚本 + 调用计数
    local clock = 100.0
    local reads = { slots = 0, components = 0, fields = 0 }
    local world = { slots = { wield_0 = 469, wield_1 = nil }, rows = { mag = 'row-mag' },
                    frame_fields = nil, fail_components = nil }
    local access = {
        now = function() return clock end,
        slots = function() reads.slots = reads.slots + 1 return world.slots end,
        components = function(entity)
            reads.components = reads.components + 1
            if world.fail_components ~= nil then
                return nil, world.fail_components
            end
            return { entity = entity, mag = 'row-mag' }
        end,
        fields = function()
            reads.fields = reads.fields + 1
            return world.frame_fields
        end,
    }
    local unit = reload.new(nil, access)
    world.frame_fields = fields({})

    local first = reload.snapshot(unit, 1)
    env.equal(type(first), 'table', '注入读取面后给出快照')
    env.equal(first.slot_index, 1, '一号位槽序为 1')
    env.equal(first.weapon_entity, 469, '快照记录槽实体')
    env.equal(first.reloading, false, '状态位按布尔折出')
    env.equal(first.mag_ammo, 4, '弹匣当前值原样带入')
    env.equal(first.ability_id, 2764, '能力编号原样带入')
    env.near(first.time, 100.0, 1e-12, '快照带时钟读数')
    env.equal(reads.fields, 1, '首帧读字段一次')

    -- ③ 同帧缓存：同一帧重复取快照不重复读内存；换帧才重读
    local again = reload.snapshot(unit, 1)
    env.check(again == first, '同一帧返回同一份快照')
    env.equal(reads.fields, 1, '同帧不重复读字段')
    reload.snapshot(unit, 2)
    env.equal(reads.fields, 2, '换帧重新读字段')

    -- ④ 缺必读字段：报缺哪个，不拿 0 冒充
    world.frame_fields = fields({}, { 'ability_running' })
    local broken, broken_why = reload.snapshot(unit, 3)
    env.equal(broken, nil, '必读字段缺失时快照作废')
    env.equal(broken_why, 'missing:ability_running', '报出缺失字段名')
    world.frame_fields = fields({})

    -- ⑤ 换槽：持握槽变化时必须重查该槽实体并重取组件行
    local before_components, before_rebuilt = reads.components, unit.rebuilt
    world.slots = { wield_0 = nil, wield_1 = 512 }
    local second = reload.snapshot(unit, 4)
    env.equal(second.slot_index, 2, '换槽后槽序为 2')
    env.equal(second.weapon_entity, 512, '换槽后实体号更新')
    env.equal(reads.components, before_components + 1, '换槽后重取组件行')
    env.check(unit.rebuilt > before_rebuilt, '重建计数自增')

    -- ⑥ 映射失效：换到新槽（必然重取组件行）时取不到，原样上报原因并清缓存，下一帧重走链
    world.slots = { wield_0 = 777, wield_1 = nil }
    world.fail_components = 'map-absent'
    local missing, missing_why = reload.snapshot(unit, 5)
    env.equal(missing, nil, '组件行取不到时快照作废')
    env.equal(missing_why, 'map-absent', '原样上报映射失效')
    world.fail_components = nil
    local recovered = reload.snapshot(unit, 6)
    env.equal(type(recovered), 'table', '下一帧重走链后恢复')
    env.equal(recovered.weapon_entity, 777, '恢复后绑到新槽实体')
    world.slots = { wield_0 = 469, wield_1 = nil }

    -- ⑦ 起止沿与时长：沿上记录起点，沿下给出实测秒数
    local cycle = reload.new(nil, access)
    world.frame_fields = fields({ reloading = 0 })
    reload.edge(cycle, reload.snapshot(cycle, 10))
    clock = 200.0
    world.frame_fields = fields({ reloading = 1 })
    local started = reload.snapshot(cycle, 11)
    env.equal(reload.edge(cycle, started), 'start', '状态位上升沿报开始')
    world.frame_fields = fields({ reloading = 1 })
    env.equal(reload.edge(cycle, reload.snapshot(cycle, 12)), nil, '换弹中无沿')
    env.equal(reload.duration(cycle, started), nil, '换弹未结束时不给时长')
    clock = 202.5
    world.frame_fields = fields({ reloading = 0 })
    local closed = reload.snapshot(cycle, 13)
    env.equal(reload.edge(cycle, closed), 'end', '状态位下降沿报结束')
    env.near(reload.duration(cycle, closed), 2.5, 1e-9, '给出本次换弹实测时长')

    -- ⑧ 可开火判定：弹匣或腔室有弹即可，读不到时报缺失
    env.equal(reload.ready_to_fire(cycle, fields({ reloading = true, mag_ammo = 4 })), true,
              '换弹中且有弹即可开火')
    env.equal(reload.ready_to_fire(cycle, fields({ reloading = true, mag_ammo = 0,
                                                   mag_chamber_round = 0 })), false, '空仓不可开火')
    env.equal(reload.ready_to_fire(cycle, fields({ reloading = false, mag_ammo = 4 })), false,
              '未在换弹中不算命中窗口')
    local can, can_why = reload.ready_to_fire({}, { reloading = true })
    env.equal(can, nil, '两处弹药都读不到时不给判定')
    env.equal(can_why, 'missing:mag_ammo', '报出缺失字段名')

    -- ⑨ 写路径：注入函数时按原语义转发
    local writes = 0
    local busy = reload.new(function() writes = writes + 1 return true end)
    local wrote, wrote_note = reload.send(busy)
    env.equal(wrote, true, '写路径转发成功')
    env.equal(wrote_note, 'reported', '写路径自述结果')
    env.equal(writes, 1, '写路径只调用一次')

    -- ⑩ 窗口门：只读传入快照，不访问内存、不触写路径，四种失败各用具名原因
    local open_before, fields_before = writes, reads.fields
    env.equal(reload.window(cycle, nil), nil, '没有快照时窗口判定为空')
    local _, no_snap = reload.window(cycle, nil)
    env.equal(no_snap, 'no-snapshot', '缺快照原因具名为 no-snapshot')
    env.equal(reload.window(cycle, { reloading = false, mag_reserve = 5 }), false,
              '未在换弹时窗口关闭')
    local _, not_reloading = reload.window(cycle, { reloading = false, mag_reserve = 5 })
    env.equal(not_reloading, 'not-reloading', '未换弹原因具名为 not-reloading')
    local missing_window, missing_window_why = reload.window(cycle, { reloading = true })
    env.equal(missing_window, nil, '余弹读不到时不给布尔结论（不以 false 冒充）')
    env.equal(missing_window_why, 'read-failed', '余弹读不到原因具名为 read-failed')
    env.equal(reload.window(cycle, { reloading = true, mag_reserve = 0 }), false, '余弹耗尽时窗口关闭')
    local _, empty_reserve = reload.window(cycle, { reloading = true, mag_reserve = 0 })
    env.equal(empty_reserve, 'empty-reserve', '余弹耗尽原因具名为 empty-reserve')
    env.equal(reload.window(cycle, { reloading = true, mag_reserve = 5 }), true, '换弹中且余弹为正时窗口打开')
    env.equal(reads.fields, fields_before, '窗口判定不额外读字段')
    env.equal(writes, open_before, '窗口判定不触写路径')

    -- ⑪ 总闸：显式关闭时写路径恒 false/disabled 且一次都不调用；未接线(nil)与开启(true)不改变既有语义
    local gated = reload.new(function() writes = writes + 1 return true end, access)
    gated.instant_enabled = false
    local gated_sent, gated_note = reload.send(gated)
    env.equal(gated_sent, false, '总闸关闭时写路径返回假')
    env.equal(gated_note, 'disabled', '总闸关闭时原因具名为 disabled')
    env.equal(writes, open_before, '总闸关闭时写路径一次都不调用')
    gated.instant_enabled = nil
    local plain_sent, plain_note = reload.send(gated)
    env.equal(plain_sent, true, '未接线(nil)时保持既有转发语义')
    env.equal(plain_note, 'reported', '未接线(nil)时自述结果不变')
    gated.instant_enabled = true
    env.equal(reload.send(gated), true, '总闸开启时按原语义转发')
    gated.instant_enabled = false
    gated.request = nil
    env.equal(reload.send(gated), false, '总闸优先于写路径缺失')
    local _, gated_why = reload.send(gated)
    env.equal(gated_why, 'disabled', '总闸关闭时即使没有写路径也报 disabled')
end
