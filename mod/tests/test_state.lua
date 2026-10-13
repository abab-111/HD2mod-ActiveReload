-- 循环状态机：初始态、开始、推进、命中（含区间端点）、按错加时、每轮一次判定、作废、扫到底。
-- 加时比例覆盖默认值 0.20 与两个端点 0、1.0，并检查按错后竖线速度严格下降。

return function(env)
    local zone = env.modules['core/zone']
    local timeline = env.modules['core/timeline']
    local state = env.modules['core/state']

    -- 随机源固定为 0 时区间为 0.20 到 0.40
    local function make(penalty)
        return state.new({
            rng = function() return 0 end,
            zone = { width = 0.20, start_min = 0.20, start_max = 0.50 },
            cycle = { fallback_seconds = 2.0, sweep_start = 0.0, penalty_per_miss = penalty },
            pick_zone = zone.pick,
            hit = zone.hit,
            position_at = timeline.position,
            duration_of = timeline.duration,
        })
    end

    local cycle = make(0.20)
    env.equal(cycle.phase, state.IDLE, '初始为空闲')
    env.equal(cycle.misses, 0, '初始按错计数为零')
    env.near(cycle.duration, 2.0, 1e-12, '初始时长取兜底时长')
    env.near(cycle.position, 0.0, 1e-12, '初始位置为扫过起点')

    state.begin(cycle)
    env.equal(cycle.phase, state.SWEEP, '开始后进入扫过')
    env.near(cycle.zone_start, 0.20, 1e-12, '开始后取到区间起点')
    env.near(cycle.zone_finish, 0.40, 1e-12, '开始后取到区间终点')
    env.near(cycle.elapsed, 0.0, 1e-12, '开始后计时归零')
    env.near(cycle.duration, 2.0, 1e-12, '未给基础时长时用兜底时长')

    state.begin(cycle, 3.0)
    env.near(cycle.duration, 3.0, 1e-12, '开始时可指定本轮基础时长')
    state.begin(cycle, 0)
    env.near(cycle.duration, 2.0, 1e-12, '基础时长为零时回退兜底时长')
    state.begin(cycle, -1.0)
    env.near(cycle.duration, 2.0, 1e-12, '基础时长为负时回退兜底时长')

    -- 区间端点：闭区间内外的分界，条长为 1，起点 0.20，终点 0.40，时长 2.0
    state.begin(cycle)
    state.advance(cycle, 0.40)
    env.near(cycle.position, 0.20, 1e-12, '推进到区间起点')
    env.equal(state.press(cycle), 'hit', '落在区间起点上判定为命中')

    state.begin(cycle)
    state.advance(cycle, 0.80)
    env.near(cycle.position, 0.40, 1e-12, '推进到区间终点')
    env.equal(state.press(cycle), 'hit', '落在区间终点上判定为命中')

    state.begin(cycle)
    state.advance(cycle, 0.40 - 1e-9)
    env.equal(state.press(cycle), 'miss', '略早于区间起点判定为按错')

    -- 完成度为零与一
    state.begin(cycle)
    env.near(cycle.position, 0.0, 1e-12, '本轮起点即完成度为零')
    env.equal(state.press(cycle), 'miss', '完成度为零且区间不在起点时判定为按错')
    env.equal(cycle.judged, true, '按错后本轮标记为已判定')
    env.equal(state.press(cycle), 'ignored', '按错后本轮不再接受判定')

    state.begin(cycle)
    state.advance(cycle, 2.0)
    env.equal(cycle.phase, state.IDLE, '扫到末端且未判定时回到空闲')
    env.near(cycle.position, 1.0, 1e-12, '扫到末端时位置在条长末端')
    env.equal(state.press(cycle), 'ignored', '空闲时按下不产生判定')
    env.equal(cycle.misses, 0, '未判定的轮次不产生按错记录')
    state.advance(cycle, 1.0)
    env.near(cycle.position, 1.0, 1e-12, '空闲时推进不再改变位置')

    -- 加时比例为 0.20：本轮总时长变为 1.2 倍，竖线速度严格下降
    local slow = make(0.20)
    state.begin(slow)
    local before = (1 - slow.origin) / slow.duration
    env.equal(state.press(slow), 'miss', '起点不在区间内判定为按错')
    env.equal(slow.misses, 1, '按错后计数加一')
    env.near(slow.duration, 2.4, 1e-12, '按错一次后本轮总时长变为 1.2 倍')
    env.near(slow.offset, 0.0, 1e-12, '在起点按错时已用时为零')
    env.check((1 - slow.origin) / slow.duration < before, '按错后竖线速度严格下降')

    -- 加时比例为 0：总时长与速度都不变
    local plain = make(0.0)
    state.begin(plain)
    env.equal(state.press(plain), 'miss', '加时比例为 0 时仍判定为按错')
    env.near(plain.duration, 2.0, 1e-12, '加时比例为 0 时总时长不变')
    env.near((1 - plain.origin) / plain.duration, 0.5, 1e-12, '加时比例为 0 时速度不变')

    -- 加时比例为 1.0：总时长翻倍
    local half = make(1.0)
    state.begin(half)
    env.equal(state.press(half), 'miss', '加时比例为 1.0 时仍判定为按错')
    env.near(half.duration, 4.0, 1e-12, '加时比例为 1.0 时总时长翻倍')

    -- 中途按错：已用时间计入偏移，剩余时长按比例延长，位置停在按错处继续
    local mid = make(0.20)
    state.begin(mid)
    state.advance(mid, 1.0)
    local mark = mid.position
    local pace = (1 - mid.origin) / mid.duration
    env.equal(state.press(mid), 'miss', '位置在区间右侧判定为按错')
    env.near(mid.offset, 1.0, 1e-12, '按错时已用时计入偏移')
    env.near(mid.elapsed, 0.0, 1e-12, '按错后本段计时归零')
    env.near(mid.duration, 1.4, 1e-12, '剩余时长等于本轮总时长减去已用时')
    env.near(mid.origin, mark, 1e-12, '按错后以按错处为新的扫过起点')
    env.near(mid.position, mark, 1e-12, '按错后位置保持在按错处')
    env.check((1 - mid.origin) / mid.duration < pace, '中途按错后竖线速度严格下降')

    -- 作废：本轮状态清零，不留判定与按错记录
    local void = make(0.20)
    env.equal(state.interrupt(void), false, '空闲时作废无效')
    state.begin(void)
    state.advance(void, 0.1)
    env.equal(state.press(void), 'miss', '作废前先按错一次')
    env.equal(state.interrupt(void), true, '扫过中可作废')
    env.equal(void.phase, state.IDLE, '作废后回到空闲')
    env.equal(void.misses, 0, '作废后按错记录清零')
    env.equal(void.judged, false, '作废后判定标记清零')
    env.near(void.offset, 0.0, 1e-12, '作废后偏移清零')
    env.near(void.elapsed, 0.0, 1e-12, '作废后计时清零')
    env.equal(state.interrupt(void), false, '作废后再次作废无效')

    -- 新一轮：时长回到本轮基础时长
    state.begin(void)
    state.advance(void, 5.0)
    env.near(void.elapsed, void.duration, 1e-12, '推进超过时长时计时截断在总时长')
    env.near(void.duration, 2.0, 1e-12, '新一轮回到基础时长')

    -- 用例 9：只读视图字段齐备，逐字转出本轮的九个字段（window 由入口每帧写入）
    local viewed = state.view(void)
    local count = 0
    for _ in pairs(viewed) do
        count = count + 1
    end
    env.equal(count, 9, '视图字段集为九项')
    for _, key in ipairs({ 'phase', 'judged', 'misses', 'elapsed', 'duration',
                           'position', 'zone_start', 'zone_finish', 'window' }) do
        env.check(viewed[key] ~= nil, '视图含字段 ' .. key)
    end
    env.equal(viewed.phase, 'idle', '视图转出本轮相位')
    env.equal(viewed.judged, false, '视图转出判定标记')
    env.equal(viewed.misses, 0, '视图转出按错计数')
    env.near(viewed.duration, 2.0, 1e-12, '视图转出本轮总时长')
    env.equal(viewed.window, false, '未接线时窗口标记为假')
    void.window = true
    env.equal(state.view(void).window, true, '入口写入窗口标记后视图如实转出')
    void.window = false

    -- 用例 13：视图每帧新建、回改不回写；连续两轮取值互不相同，无跨帧脏值
    local roll = { value = 0.0 }
    local live = state.new({
        rng = function() return roll.value end,
        zone = { width = 0.20, start_min = 0.20, start_max = 0.50 },
        cycle = { fallback_seconds = 2.0, sweep_start = 0.0, penalty_per_miss = 0.20 },
        pick_zone = zone.pick,
        hit = zone.hit,
        position_at = timeline.position,
        duration_of = timeline.duration,
    })
    state.begin(live)
    state.advance(live, 0.30)
    local first = state.view(live)
    roll.value = 0.50
    state.begin(live)
    state.advance(live, 1.50)
    local second = state.view(live)
    env.check(first ~= second, '视图每帧新建，不与上一帧共享同一张表')
    env.near(first.zone_start, 0.20, 1e-12, '上一帧视图仍留上一轮的区间起点')
    env.near(first.zone_finish, 0.40, 1e-12, '上一帧视图仍留上一轮的区间终点')
    env.near(first.position, 0.15, 1e-12, '上一帧视图仍留上一轮的完成度')
    env.near(second.zone_start, 0.35, 1e-12, '本帧视图取到本轮的区间起点')
    env.near(second.zone_finish, 0.55, 1e-12, '本帧视图取到本轮的区间终点')
    env.near(second.position, 0.75, 1e-12, '本帧视图取到本轮的完成度')
    env.check(second.zone_start ~= first.zone_start and second.position ~= first.position,
              '两轮取值互不相同，未残留上一轮脏值')
end
