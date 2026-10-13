-- 区间：起点范围、区间宽度、命中判定（含端点与零宽边界）

local function constant(value)
    return function() return value end
end

return function(env)
    local zone = env.modules['core/zone']
    local rules = { width = 0.20, start_min = 0.20, start_max = 0.50 }

    local start, finish = zone.pick(constant(0), rules)
    env.near(start, 0.20, 1e-12, '随机源取下限时区间起点为起点范围下限')
    env.near(finish, 0.40, 1e-12, '区间终点为起点加宽度')

    start, finish = zone.pick(constant(1), rules)
    env.near(start, 0.50, 1e-12, '随机源取上限时区间起点为起点范围上限')
    env.near(finish, 0.70, 1e-12, '区间终点随起点一起前移')

    start, finish = zone.pick(constant(0.5), rules)
    env.near(start, 0.35, 1e-12, '随机源取中值时区间起点居中')
    env.check(finish <= 1.0, '区间终点不越过条长末端')

    env.check(zone.hit(0.20, 0.40, 0.20) == true, '区间左端点算命中')
    env.check(zone.hit(0.20, 0.40, 0.40) == true, '区间右端点算命中')
    env.check(zone.hit(0.20, 0.40, 0.30) == true, '区间内部算命中')
    env.check(zone.hit(0.20, 0.40, 0.199) == false, '区间左端外侧不算命中')
    env.check(zone.hit(0.20, 0.40, 0.401) == false, '区间右端外侧不算命中')
    env.check(zone.hit(0, 0, 0) == true, '零宽区间在零位置算命中')
    env.check(zone.hit(1.0, 1.0, 1.0) == true, '条长末端算命中')
    env.check(zone.hit(1.0, 1.0, 0.99) == false, '条长末端之前不算命中')

    -- 固定种子 20261005：测试过程本身可复现（运行时玩法随机不受此约束）
    math.randomseed(20261005)
    local first_start, first_finish = zone.pick(math.random, rules)
    math.randomseed(20261005)
    local second_start, second_finish = zone.pick(math.random, rules)
    env.near(first_start, second_start, 1e-12, '固定种子下区间起点可复现')
    env.near(first_finish, second_finish, 1e-12, '固定种子下区间终点可复现')

    math.randomseed(20261005)
    for index = 1, 64 do
        local low, high = zone.pick(math.random, rules)
        env.check(low >= rules.start_min - 1e-12, '起点不早于起点范围下限')
        env.check(low <= rules.start_max + 1e-12, '起点不晚于起点范围上限')
        env.near(high - low, rules.width, 1e-12, '区间宽度等于约定宽度')
        env.check(high <= 1.0 + 1e-12, '区间终点不越过条长末端')
    end

    -- 命中谓词与位置映射的合成面（诊断场 no-hit 判读口径）：命中只取决于本轮随机区间与归一化位置，
    -- 不存在固定时间门槛；同一实测秒数在不同随机区间下可命中也可落空（双态），故场次读数不可当门槛用。
    local timeline = env.modules['core/timeline']
    local function hit_at(start_ratio, elapsed, duration)
        local low, high = zone.pick(constant(start_ratio), rules)
        return zone.hit(low, high, timeline.position(elapsed, duration, 0.0))
    end
    env.check(hit_at(0.0, 1.000, 2.756) == true, '区间起点取下限时同一实测秒数命中（归一化位置落在区间内）')
    env.check(hit_at(1.0, 1.000, 2.756) == false, '区间起点取上限时同一实测秒数落空（同秒数双态）')
    env.check(hit_at(0.0, 0.489, 2.756) == false, '实测秒数低于最早可命中时刻（起点下限×时长）⇒ 恒不命中')
    env.check(hit_at(0.0, 0.600, 2.756) == true, '实测秒数略高于最早可命中时刻 ⇒ 起点取下限时命中')
    env.check(hit_at(0.0, 2.756, 2.756) == false, '位置推到条长末端越出区间 ⇒ 落空（位置与秒数不是同一量纲）')
end
