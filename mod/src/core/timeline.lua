-- 时长与位置换算：纯计算，不含状态。

local timeline = {}

-- 条长末端：位置取值上界，条长按 1 归一化
local BAR_END = 1.0

-- 按错后的总时长：基础时长乘以 (1 + 每次加时比例 × 按错次数)
function timeline.duration(base, misses, penalty)
    local factor = 1 + penalty * misses
    if factor < 1 then
        factor = 1
    end
    return base * factor
end

-- 扫过位置：从起点线性走到条长末端，并按进度截断
function timeline.position(elapsed, duration, start)
    if duration <= 0 then
        return BAR_END
    end
    local ratio = elapsed / duration
    if ratio < 0 then
        ratio = 0
    elseif ratio > 1 then
        ratio = 1
    end
    return start + (BAR_END - start) * ratio
end

return timeline
