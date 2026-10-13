-- 游戏侧时间：只读取调用方注入的时钟，取不到值时返回 nil，由调用方跳过本帧。

local time = {}

function time.new(now)
    return { read = now }
end

-- 帧驱动时钟：依赖宿主每帧喂入的秒数，暂停或菜单不产帧 ⇒ 读数自动冻结，
-- 这正是「单机暂停时进度条不穿帮」所需的基准；卡顿帧（超过上限）只计数不推进。
function time.stepper(limit)
    return { seconds = 0, frames = 0, skipped = 0, limit = limit }
end

function time.feed(self, delta)
    if type(delta) ~= 'number' or delta ~= delta or delta < 0 or
       (self.limit ~= nil and delta > self.limit) then
        self.skipped = self.skipped + 1
        return false
    end
    self.seconds = self.seconds + delta
    self.frames = self.frames + 1
    return true
end

function time.read(self)
    return self.seconds
end

function time.now(self)
    if type(self.read) ~= 'function' then
        return nil
    end
    local value = self.read()
    if type(value) ~= 'number' or value ~= value then
        return nil
    end
    return value
end

function time.delta(self, previous)
    local current = time.now(self)
    if current == nil or previous == nil then
        return nil, current
    end
    if current < previous then
        return nil, current
    end
    return current - previous, current
end

return time
