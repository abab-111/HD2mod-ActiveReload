-- 按键采样：只做电平到边沿的转换，键位来源由调用方注入。
-- 同一轮只认一次按下：需要前一帧处于松开状态才算新的触发点。

local input = {}

function input.new(sample, rules)
    return {
        sample = sample,
        rules = rules,
        held = false,
        armed = not rules.release_before_new,
    }
end

-- 返回本次是否触发、以及当前是否处于松开状态
function input.poll(self)
    local down = false
    if type(self.sample) == 'function' then
        down = self.sample() == true
    end
    if not down then
        self.armed = true
    end
    local pressed = down and self.held == false and self.armed
    if pressed then
        self.armed = false
    end
    self.held = down
    return pressed, not down
end

function input.release(self)
    self.held = false
    self.armed = true
end

-- 取源（第 1 / 2 步）：源名 → 模块键。打包后非入口模块看不到入口里的 local modules，
-- 故只认显式注入的模块表（第三个参数）或全局 modules（测试桩），都没有即源缺席。
-- 键为准一映射（同 build.py 的 MODULE_ORDER），不做回退猜测：未知源名一律 source-missing。
local SOURCE_MODULE = { form_b = 'game/source_formb', bindings = 'game/source_bindings', key = 'game/source_key' }
local function pick_source(name, registry)
    local key = SOURCE_MODULE[name]
    if type(key) ~= 'string' then return nil, 'source-missing' end
    if type(registry) ~= 'table' then registry = rawget(_G, 'modules') end
    if type(registry) ~= 'table' then return nil, 'source-missing' end
    local owner = registry[key]
    if type(owner) ~= 'table' then return nil, 'source-missing' end
    return owner, nil
end

-- 装配采样器：三级取源，spec 为整块 config.inputs，任一级失败都回恒 nil + 原因的兜底采样器。
function input.native(access, spec, registry)
    if type(spec) ~= 'table' then return nil, 'no-spec' end
    local name = spec.source
    if type(name) ~= 'string' then return nil, 'no-source-name' end
    input.name, input.spec, input.digest = name, spec[name], nil
    local enabled = type(spec.sources) == 'table' and spec.sources[name]
    if enabled == false then return function() return nil, 'source-disabled' end end
    local owner, reason = pick_source(name, registry)
    if owner == nil or type(owner.new) ~= 'function' or type(spec[name]) ~= 'table' then
        return function() return nil, reason or 'source-missing' end
    end
    local object = owner.new(access, spec[name])
    if type(object) ~= 'table' or type(object.level) ~= 'function' then
        return function() return nil, 'source-broken' end
    end
    input.owner, input.object = owner, object
    if type(owner.digest) == 'function' and type(spec.form_b_fingerprint_keys) == 'table' then
        input.digest = owner.digest(spec[name], spec.form_b_fingerprint_keys)
    end
    return function() return object:level() end
end

-- 换源 spec（形如 config.inputs.form_b）：只替换 spec 并复位源对象，不动 held / armed。
function input.configure(self, spec)
    local object = self.object or input.object
    if type(spec) ~= 'table' or type(object) ~= 'table' then return false, 'no-source' end
    self.spec = spec
    if type(object.reset) == 'function' then object.reset(object, spec) end
    return true, nil
end

-- 源自证：<源名>@<spec 指纹前 8 位>；指纹缺席时如实回 nil + 原因，不编造回显。
function input.block(self)
    if type(self.name) ~= 'string' then return nil, 'no-source-name' end
    if type(self.digest) ~= 'string' then return nil, 'no-digest' end
    return self.name .. '@' .. self.digest
end

return input
