-- 帧驱动适配件（两构型共享）：把入口的帧函数挂到宿主每帧链上，并在其后调用可选的绘制回调；
-- 不读内存、不写内存。
-- 挂载只走随包运行时件的守卫接口，原更新函数与退出链的转发由守卫负责；env 供测试注入，缺省宿主全局。
local driver = {}
driver.NAME = 'active_reload'
local function say(self, line) if self.log ~= nil then self.log(line) end end
local function fail(self, tag, why)
    local text = tostring(why)
    if text:find('already installed', 1, true) ~= nil then tag = 'already-installed'
    elseif text:find('game update unavailable', 1, true) ~= nil then tag = 'update-missing'
    else tag = tag .. ':' .. text end
    say(self, 'DRIVER status=skipped reason=' .. tag)
    return false, tag
end

function driver.new(deps)
    if type(deps) ~= 'table' or type(deps.frame) ~= 'function' then return nil, 'no-frame' end
    local modules, config = deps.modules, deps.config
    local log_lib = (type(modules) == 'table') and modules['log'] or nil
    local use_log = type(log_lib) == 'table' and type(log_lib.info) == 'function' and deps.logger ~= nil
    local paint = deps.paint
    if type(paint) ~= 'function' then paint = nil end
    local object = { frame = deps.frame, paint = paint, modules = modules, config = config,
        heartbeat = (type(config) == 'table' and type(config.driver) == 'table') and config.driver.heartbeat_frames or nil,
        env = (type(deps.env) == 'table') and deps.env or _G,
        runtime = (type(modules) == 'table') and modules['game/vendor/bingus_runtime'] or nil,
        attached = false, frames = 0, elapsed = 0 }
    object.log = use_log and function(line) log_lib.info(deps.logger, line) end or nil
    return setmetatable(object, { __index = driver })
end

function driver.attach(self)
    local runtime, env = self.runtime, self.env
    if type(runtime) ~= 'table' or type(runtime.guard) ~= 'function' then
        say(self, 'DRIVER status=skipped reason=no-runtime')
        return false, 'no-runtime'
    end
    if self.attached == true then say(self, 'DRIVER status=skipped reason=already-installed') return false, 'already-installed' end
    local made, guard = pcall(runtime.guard, { name = driver.NAME, log = self.log, env = env,
        step = function(delta) return driver.step(self, delta) end,
        stop = function(reason) return driver.stop(self, reason) end })
    if made ~= true then return fail(self, 'guard-failed', guard) end
    local ready, problem = pcall(guard.install, guard)
    if ready ~= true then return fail(self, 'install-failed', problem) end
    self.guard, self.attached = guard, true
    say(self, 'DRIVER status=attached name=' .. driver.NAME)
    return true, 'attached'
end

function driver.step(self, delta)
    self.frames = self.frames + 1
    self.elapsed = self.elapsed + (type(delta) == 'number' and delta or 0)
    if self.frames == 1 then say(self, 'DRIVER first-frame dt=' .. tostring(delta))
    elseif self.heartbeat ~= nil and self.heartbeat > 0 and self.frames % self.heartbeat == 0 then
        say(self, 'DRIVER frames=' .. tostring(self.frames) .. ' elapsed=' .. string.format('%.3f', self.elapsed))
    end
    local phase = self.frame(delta)
    if self.paint ~= nil then self.paint() end
    return phase
end

function driver.stop(self, reason) say(self, 'DRIVER status=stopped reason=' .. tostring(reason)) end
return driver
