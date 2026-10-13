-- 命中区间：纯计算，随机源与规则由调用方注入。

local zone = {}

-- 在允许的起点范围内取一个区间，返回起点与终点（条长比例）
function zone.pick(rng, rules)
    local span = rules.start_max - rules.start_min
    local start = rules.start_min + rng() * span
    return start, start + rules.width
end

-- 位置是否落在区间内
function zone.hit(start, finish, position)
    if position < start then
        return false
    end
    return position <= finish
end

return zone
