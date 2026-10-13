-- 桩用例（不是门，见 mod/tests/README 角色表）：写批次顺序、记账、回滚与两道闸门。
return function(env)
    local instant = env.modules['game/instant']
    if not (type(instant) == 'table' and type(instant.new) == 'function') then
        env.check(false, 'game/instant 模块未加载')
        return
    end

    local MAG, ABILITY, RELOAD = 33554432, 50331648, 67108864
    local RUNNING_AT, RESERVE_AT, AMMO_AT = 16, 0, 4
    local STAGE_AT, STAGE_START = 0, 4          -- 换弹阶段标志（写 C 的落点）；初值 4＝写入前快照值
    local native = { components = {
        { key = 'mag', arrays = { { values = { mag_reserve = { RESERVE_AT, 'u32' },
                                               mag_ammo = { AMMO_AT, 'u32' } } } } },
        { key = 'ability', arrays = { { values = { ability_running = { RUNNING_AT, 'u8' } } } } },
        { key = 'reload', arrays = { { values = { reload_stage = { STAGE_AT, 'u32' } } } } },
    } }

    local rows, calls, fail, frozen, fail_read = {}, {}, {}, {}, {}
    local report = rawget(_G, '__report')
    local function emit(label, text)
        if report ~= nil then
            report(label .. ' ' .. tostring(text))
        end
    end
    local function u32(value)
        return string.char(value % 256, math.floor(value / 256) % 256,
                           math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
    end
    local function put(base, offset, bytes)
        if frozen[base] then return end
        for index = 1, #bytes do rows[base][offset + index - 1] = string.byte(bytes, index) end
    end
    local function reset(reserve, ammo, running)
        rows[MAG] = {}
        for index = 0, 7 do rows[MAG][index] = string.byte(u32(0), index + 1) end
        rows[ABILITY] = {}
        for index = 0, 63 do rows[ABILITY][index] = 0 end
        rows[RELOAD] = {}
        for index = 0, 63 do rows[RELOAD][index] = 0 end
        local bytes = u32(reserve)
        for index = 0, 3 do rows[MAG][RESERVE_AT + index] = string.byte(bytes, index + 1) end
        bytes = u32(ammo)
        for index = 0, 3 do rows[MAG][AMMO_AT + index] = string.byte(bytes, index + 1) end
        rows[ABILITY][RUNNING_AT] = running
        bytes = u32(STAGE_START)
        for index = 0, 3 do rows[RELOAD][STAGE_AT + index] = string.byte(bytes, index + 1) end
    end
    local function read(address, size)
        for base, cells in pairs(rows) do
            if address >= base and address + size <= base + 64 then
                if fail_read[base] then return nil end
                local out = {}
                for index = 0, size - 1 do out[index + 1] = string.char(cells[address - base + index] or 0) end
                return table.concat(out)
            end
        end
        return nil
    end
    local function decode(base, offset, count)
        local value = 0
        for index = count - 1, 0, -1 do
            value = value * 256 + (rows[base][offset + index] or 0)
        end
        return value
    end
    local function batch(base, size, changes)
        calls[#calls + 1] = { base = base, size = size, changes = changes }
        if fail[#calls] then return false, 0 end
        for index = 1, #changes do put(base, changes[index][1], changes[index][2]) end
        return true, #changes
    end

    local logs = {}
    local function make(config, without_batch)
        local deps = { config = config, native = native, read = read, batch = batch,
                       locate = function(kind)
                           if kind == 'mag' then return MAG end
                           if kind == 'ability' then return ABILITY end
                           if kind == 'reload' then return RELOAD end
                           return nil
                       end,
                       log = function(line) logs[#logs + 1] = line end }
        if without_batch then deps.batch = nil end
        return instant.new(deps)
    end
    local function clear()
        calls, fail, frozen, fail_read, logs = {}, {}, {}, {}, {}
    end

    -- 闸门一：默认关闭（config.instant.enabled=false）时一律拒写，且不碰写面。
    clear()
    reset(30, 5, 1)
    local off = make({ enabled = false, capacity_default = 0 })
    local view = off:complete({ reloading = true, mag_reserve = 30 })
    env.equal(view.status, 'refused', '关闭态应拒写')
    env.equal(view.reason, 'disabled', '关闭态原因应为 disabled')
    env.equal(#calls, 0, '关闭态不得调用写面')
    env.equal(view.batches, 0, '关闭态批次数应为 0')

    -- 闸门二：窗口外一律拒写（require_window 不可关）。
    clear()
    local live = make({ enabled = true, require_window = true, capacity_default = 0, capacity_source = 'snapshot' })
    env.equal(live:complete({ reloading = false, mag_reserve = 30 }).reason, 'window', '窗口外应回 window')
    env.equal(live:complete({ reloading = true, mag_reserve = 0 }).reason, 'window', '备弹不足应回 window')
    env.equal(live:complete({ reloading = false, mag_reserve = 30, window = true }).reason, 'window',
              '窗口判据只由快照推导；快照上的 window 字段不作数')
    env.equal(#calls, 0, '窗口外不得调用写面')

    -- 正路：先 B 后 A、同帧、单批次；账目单位＝每写扣 1 整匣、弹匣补满（与自然换弹同额）。
    clear()
    reset(4, 3, 1)                                   -- 写入时备弹 4 匣、弹匣 3 发
    local snap = { reloading = true, mag_reserve = 4, mag_ammo_max = 5 }
    local ok = live:complete(snap)
    env.equal(ok.status, 'written', '窗口内应完成写入')
    env.equal(ok.rolled_back, false, '成功轮不得回滚')
    env.equal(#calls, 3, '一轮应恰好三次写调用（先 B、再 A、后 C）')
    env.equal(calls[1].base, ABILITY, '第一批必须是写 B（终止）')
    env.equal(calls[1].changes[1][1], RUNNING_AT, '写 B 应落在 ability_running 偏移')
    env.equal(calls[1].changes[1][2], string.char(0), '写 B 应把 ability_running 清 0')
    env.equal(calls[2].base, MAG, '第二批必须是写 A（补弹）')
    env.equal(calls[2].changes[1][1], RESERVE_AT, '写 A 应先落 mag_reserve')
    env.equal(calls[2].changes[2][1], AMMO_AT, '写 A 应再落 mag_ammo')
    env.equal(calls[3].base, RELOAD, '第三批必须是写 C（换弹阶段标志收尾）')
    env.equal(calls[3].changes[1][1], STAGE_AT, '写 C 应落在 reload_stage 偏移')
    env.equal(calls[3].changes[1][2], u32(0), '写 C 应把 reload_stage 归零')
    env.equal(decode(MAG, RESERVE_AT, 4), 3, '补弹后备弹应为 reserve-1（整匣扣减）')
    env.equal(decode(MAG, AMMO_AT, 4), 5, '补弹后弹匣应为 capacity（补满）')
    env.equal(rows[ABILITY][RUNNING_AT], 0, '写 B 落地后 ability_running 应为 0')
    env.equal(decode(RELOAD, STAGE_AT, 4), 0, '写 C 落地后 reload_stage 应为 0（F1 补写）')
    env.equal(ok.batches, 1, '一轮只许一个写批次')

    -- 账目单位①：与自然换弹同额 —— 备弹按整匣扣 1、弹匣补满（不依赖写入时读值，也不依赖开帧余弹）。
    clear()
    reset(4, 3, 1)                                   -- 写入时备弹 4 匣、弹匣 3 发
    local carried = live:complete({ reloading = true, mag_reserve = 4, mag_ammo_max = 5 })
    env.equal(carried.status, 'written', '备弹 4 匣应完成写入')
    env.equal(decode(MAG, AMMO_AT, 4), 5, '弹匣应补满至容量 5')
    env.equal(decode(MAG, RESERVE_AT, 4), 3, '备弹应扣 1 整匣（4-1=3）')
    emit('账目单位①备弹 4', 'ammo=' .. tostring(decode(MAG, AMMO_AT, 4)) ..
         ' reserve=' .. tostring(decode(MAG, RESERVE_AT, 4)) .. ' capacity=5')

    -- 账目单位②：备弹 1 匣 ⇒ 写入后归零（与自然换弹同额）。
    clear()
    reset(1, 0, 1)
    local spent_one = live:complete({ reloading = true, mag_reserve = 1, mag_ammo_max = 5 })
    env.equal(spent_one.status, 'written', '备弹 1 匣应完成写入')
    env.equal(decode(MAG, AMMO_AT, 4), 5, '弹匣应补满至容量 5')
    env.equal(decode(MAG, RESERVE_AT, 4), 0, '备弹应扣 1 整匣（1-1=0）')
    emit('账目单位②备弹 1', 'ammo=' .. tostring(decode(MAG, AMMO_AT, 4)) ..
         ' reserve=' .. tostring(decode(MAG, RESERVE_AT, 4)) .. ' capacity=5')

    -- 账目单位③：备弹 0 ⇒ 弃本轮，且一个字节都不写（fail-safe：不写＝让自然完成接管，优于写错账）。
    clear()
    reset(0, 0, 1)
    local no_reserve = live:complete({ reloading = true, mag_reserve = 1, mag_ammo_max = 5 })
    env.equal(no_reserve.status, 'abandoned', '备弹 0 应弃本轮（abandoned）')
    env.equal(no_reserve.reason, 'no-reserve', '弃轮原因应为 no-reserve')
    env.equal(#calls, 0, '备弹 0 时不得写任何一写')
    emit('账目单位③备弹 0 弃写', 'status=' .. tostring(no_reserve.status) ..
         ' reason=' .. tostring(no_reserve.reason) .. ' calls=' .. tostring(#calls))

    -- 账目单位④：容量非测试包络（≠5）⇒ 弃本轮（跨武器 reserve 单位未验，宁可弃写；不写＝让自然完成接管）。
    clear()
    reset(10, 0, 1)
    local off_profile = live:complete({ reloading = true, mag_reserve = 10, mag_ammo_max = 30 })
    env.equal(off_profile.status, 'abandoned', '容量 30 应弃本轮（abandoned）')
    env.equal(off_profile.reason, 'unsupported-profile', '弃轮原因应为 unsupported-profile')
    env.equal(#calls, 0, '包络外容量时不得写任何一写')
    emit('账目单位④容量 30 弃写', 'status=' .. tostring(off_profile.status) ..
         ' reason=' .. tostring(off_profile.reason) .. ' calls=' .. tostring(#calls))

    -- 容量未采集：capacity 解析不出数（快照无 mag_ammo_max 且无默认值）⇒ 拒写，不碰写面。
    clear()
    reset(4, 3, 1)
    local nocap = make({ enabled = true, require_window = true, capacity_source = 'snapshot' })
    local no_capacity = nocap:complete({ reloading = true, mag_reserve = 4 })
    env.equal(no_capacity.status, 'refused', '容量未采集应拒写')
    env.equal(no_capacity.reason, 'no-capacity', '拒写原因应为 no-capacity')
    env.equal(#calls, 0, '容量未采集时不得调用写面')

    -- 回滚：第二批失败必须连第一批一起回滚，两字段回写快照、本轮置 voided。
    clear()
    reset(30, 5, 1)
    local spent = live:describe().batches
    fail[2] = true
    local voided = live:complete(snap)
    env.equal(voided.status, 'voided', '第二批失败应回滚并置 voided')
    env.equal(voided.rolled_back, true, '应记账为已回滚')
    env.equal(voided.reason, 'failed:write-a/0', '应记下失败串（含已落地项数）')
    env.equal(#calls, 5, '回滚写计入同一轮：写 A 失败时两次首发 ＋ 三次回写，且不得重试')
    env.equal(decode(MAG, RESERVE_AT, 4), 30, '回滚后备弹应等于快照值')
    env.equal(decode(MAG, AMMO_AT, 4), 5, '回滚后弹匣应等于快照值')
    env.equal(rows[ABILITY][RUNNING_AT], 1, '回滚后 ability_running 应等于快照值')
    env.equal(decode(RELOAD, STAGE_AT, 4), STAGE_START, '回滚后 reload_stage 应等于快照值')
    env.equal(live:describe().batches - spent, 1, '含回滚写仍只算一个写批次')

    -- 回读不符：写自报成功但回读不符，同样必须回写快照并置 voided。
    clear()
    reset(30, 5, 1)
    frozen[MAG] = true
    local mismatch = live:complete(snap)
    env.equal(mismatch.status, 'voided', '回读不符应置 voided')
    env.equal(mismatch.reason, 'readback-mismatch', '应标明回读不符')
    env.equal(decode(MAG, AMMO_AT, 4), 5, '回读不符应把两字段回写到快照值')
    env.equal(rows[ABILITY][RUNNING_AT], 1, '回读不符也要把终止写一起撤销')

    -- 回滚失败：立即停写本会话，并落一行 instant-abort（含两字段写前/写后/回读值）。
    clear()
    reset(30, 5, 1)
    fail[2], fail[4], frozen[MAG] = true, true, false
    local aborted = live:complete(snap)
    env.equal(aborted.status, 'aborted', '回滚失败应置 aborted')
    env.equal(aborted.reason, 'rollback-failed', '回滚失败原因应为 rollback-failed')
    env.equal(live:describe().write_disabled, true, '回滚失败后应停写本会话')
    env.check(type(logs[1]) == 'string' and string.sub(logs[1], 1, 13) == 'instant-abort', '应落 instant-abort 行')
    local later = live:complete(snap)
    env.equal(later.status, 'refused', '停写后应拒写')
    env.equal(later.reason, 'write-disabled', '停写原因应为 write-disabled')
    env.equal(#calls, 4, '停写后不得再调用写面（回滚在写 A 处失败 ⇒ 两次首发 ＋ 两次回写）')

    -- 快照未成：任一读不到即弃本轮，且一个字节都不写（X-1 硬条件②）。
    clear()
    reset(30, 5, 1)
    fail_read[MAG] = true
    local stub = make({ enabled = true, require_window = true, capacity_default = 0 })
    local dropped = stub:complete(snap)
    env.equal(dropped.status, 'refused', '读不到应弃本轮')
    env.equal(dropped.reason, 'read-failed', '弃轮原因应为 read-failed')
    env.equal(#calls, 0, '快照未成时不得写任何一写')

    -- 写面缺席：没有批次函数一律拒写，不得抛异常崩栈。
    clear()
    local bare = make({ enabled = true, require_window = true, capacity_default = 0 }, true)
    env.equal(bare:complete(snap).reason, 'no-write-face', '缺写面应回 no-write-face')
    env.equal(#calls, 0, '缺写面时不得调用写面')

    -- 描述表：不暴露给玩家的项不登记，但拒写态与批次数必须可查。
    local described = live:describe()
    env.equal(described.require_window, true, '窗口自闸不可关')
    env.equal(described.instant_enabled, nil, '描述表不得登记玩家可见开关')
end
