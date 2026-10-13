-- 循环状态机：空闲与扫过两态，事件为开始、推进、判定、作废。
-- 依赖（随机源、区间规则、循环规则、区间与时长算法）全部由调用方注入，本模块不做具体算法。
-- 判定每轮只有一次：按错后本轮不再接受判定，只能等本轮走完或作废重来。
-- 时间轴按段推进：命中前为一段，按错后剩余时长按比例延长、竖线从当前位置以更低速度继续。

local state = {}

state.IDLE = 'idle'
state.SWEEP = 'sweep'

function state.new(deps)
    local base = deps.cycle.fallback_seconds
    return {
        deps = deps,
        phase = state.IDLE,
        base = base,
        misses = 0,
        judged = false,
        offset = 0,
        elapsed = 0,
        duration = base,
        origin = deps.cycle.sweep_start,
        position = deps.cycle.sweep_start,
        zone_start = 0,
        zone_finish = 0,
    }
end

-- 开始一轮；base 为本轮基础时长，省略或非法时用兜底时长
function state.begin(self, base)
    local deps = self.deps
    if type(base) == 'number' and base > 0 then
        self.base = base
    else
        self.base = deps.cycle.fallback_seconds
    end
    self.phase = state.SWEEP
    self.misses = 0
    self.judged = false
    self.offset = 0
    self.elapsed = 0
    self.duration = self.base
    self.origin = deps.cycle.sweep_start
    self.zone_start, self.zone_finish = deps.pick_zone(deps.rng, deps.zone)
    self.position = deps.position_at(0, self.duration, self.origin)
    return self
end

-- 推进；扫到末端仍未判定则本轮结束，不加时
function state.advance(self, delta)
    if self.phase ~= state.SWEEP then
        return self
    end
    local deps = self.deps
    self.elapsed = self.elapsed + delta
    if self.elapsed >= self.duration then
        self.elapsed = self.duration
        self.phase = state.IDLE
    end
    self.position = deps.position_at(self.elapsed, self.duration, self.origin)
    return self
end

-- 判定：返回命中、按错或本轮不再接受判定
function state.press(self)
    if self.phase ~= state.SWEEP or self.judged then
        return 'ignored'
    end
    local deps = self.deps
    if deps.hit(self.zone_start, self.zone_finish, self.position) then
        self.phase = state.IDLE
        self.judged = true
        return 'hit'
    end
    local mark = self.position
    self.judged = true
    self.misses = self.misses + 1
    self.offset = self.offset + self.elapsed
    self.elapsed = 0
    self.origin = mark
    self.duration = deps.duration_of(self.base, self.misses, deps.cycle.penalty_per_miss) - self.offset
    self.position = deps.position_at(0, self.duration, self.origin)
    return 'miss'
end

-- 作废：本轮中断且不加时，本轮状态清零；重新开始由下一次开始负责
function state.interrupt(self)
    if self.phase ~= state.SWEEP then
        return false
    end
    self.phase = state.IDLE
    self.misses = 0
    self.judged = false
    self.offset = 0
    self.elapsed = 0
    return true
end

-- 只读视图：把本轮对外可见的字段逐字转出，每次新建一张表（不共享、不缓存，避免跨帧脏值）。
-- window 由入口每帧写入，表示本轮是否落在换弹窗口内；它不是状态机状态，两态仍只有空闲与扫过。
function state.view(self)
    return {
        phase = self.phase,
        judged = self.judged,
        misses = self.misses,
        elapsed = self.elapsed,
        duration = self.duration,
        position = self.position,
        zone_start = self.zone_start,
        zone_finish = self.zone_finish,
        window = self.window == true,
    }
end

return state
