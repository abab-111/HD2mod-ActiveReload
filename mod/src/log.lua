-- 日志：等级过滤 + 可选外部输出端点，未注入端点时退回控制台。
-- 接入共享加载器日志的做法由调用方注入 sink 完成，本模块不直接访问游戏。

local log = {}

local LEVELS = {
    debug = 1,
    info = 2,
    warn = 3,
    error = 4,
}

log.levels = LEVELS

function log.new(settings, sink)
    local self = {
        threshold = LEVELS[settings.level] or LEVELS.info,
        prefix = settings.prefix or '',
    }
    if type(sink) == 'function' then
        self.sink = sink
    else
        self.sink = function(message) print(message) end
    end
    return self
end

function log.enabled(self, level)
    local weight = LEVELS[level]
    if weight == nil then
        return false
    end
    return weight >= self.threshold
end

function log.emit(self, level, message)
    if not log.enabled(self, level) then
        return false
    end
    self.sink(tostring(self.prefix) .. tostring(level) .. ': ' .. tostring(message))
    return true
end

function log.debug(self, message)
    return log.emit(self, 'debug', message)
end

function log.info(self, message)
    return log.emit(self, 'info', message)
end

function log.warn(self, message)
    return log.emit(self, 'warn', message)
end

function log.error(self, message)
    return log.emit(self, 'error', message)
end

return log
