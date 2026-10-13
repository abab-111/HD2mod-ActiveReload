-- 读取面底座：把随包 vendor 的共享运行时读取面折成产品自己的接口（做法照 probe/src/memory.lua，只搬做法）。
-- 依赖注入：memory.new(runtime_lib, memory_lib, logger, executable_name)；缺依赖不抛异常，原因落 reason。
-- 地址域归一：本件内部唯一地址类型是 Lua 数字。交出方向必 cast 成 const void *——LuaJIT 拒收 number
-- 指针实参（原文错误串 cannot convert 'number' to 'const void *'）；收回方向必过 api.address 折成数字。
-- 任一侧漏做都不是报错而是静默降级，故两侧都在此收口。
-- 本文件对外面里没有任何写方法：默认构建零写，写能力只出现在授权构建的 instant.lua。

local memory = {}

local names = { 'available', 'read', 'pointer', 'module_base', 'reason_text', 'stats' }

-- 交出方向：number/cdata 一律 cast 成 const void *；其余原样透传（nil 即 NULL）。
local function as_const_pointer(self, value)
    if value == nil then return nil end
    local windows = type(self.api) == 'table' and self.api.windows or nil
    local ffi = windows ~= nil and windows.ffi or nil
    if ffi == nil then return value end
    local kind = type(value)
    if kind == 'number' or kind == 'cdata' then
        return ffi.cast('const void *', value)
    end
    return value
end

local function method_available(self) return self.api ~= nil end

local function method_reason_text(self) return self.reason end

local function method_read(self, address, size)
    if self.api == nil then return nil end
    self.calls = self.calls + 1
    local text = self.api.read(as_const_pointer(self, address), size)
    if text == nil then
        self.failures = self.failures + 1
        return nil
    end
    self.bytes = self.bytes + size
    return text
end

-- 收回方向：指针一律折成 Lua 数字，外部只见 number。
local function method_pointer(self, text, offset)
    if self.api == nil then return nil end
    local value = self.api.pointer(text, offset)
    if value == nil then return nil end
    return self.api.address(value)
end

local function method_module_base(self, name)
    if self.api == nil then return nil end
    local handle = self.api.module(name)
    if handle == nil and name == self.executable_name then
        handle = self.api.module(nil)
        self.fallbacks = self.fallbacks + 1
    end
    if handle == nil then return nil end
    return self.api.address(handle)
end

local function method_stats(self)
    return { calls = self.calls, bytes = self.bytes, failures = self.failures,
             fallbacks = self.fallbacks, dot_calls = self.dot_calls, reason = self.reason }
end

local methods = { available = method_available, read = method_read,
                  pointer = method_pointer, module_base = method_module_base,
                  reason_text = method_reason_text, stats = method_stats }

-- 方法一律冒号调用：点调用会把地址吃成 self，是探针已证的静默降级形态，故按名包一层守卫，
-- 误用即计数并记日志，绝不静默；stats().dot_calls 必须为 0。
local function attach(self, logger)
    for position = 1, #names do
        local name = names[position]
        local method = methods[name]
        self[name] = function(first, ...)
            if first ~= self then
                self.dot_calls = self.dot_calls + 1
                if logger ~= nil then
                    logger:error('ADAPTER dot-call method=' .. name ..
                                 ' arg_type=' .. type(first) .. ' expected=colon')
                end
                return nil
            end
            return method(self, ...)
        end
    end
end

function memory.new(runtime_lib, memory_lib, logger, executable_name)
    local self = { logger = logger, executable_name = executable_name, api = nil,
                   reason = nil, calls = 0, bytes = 0, failures = 0, fallbacks = 0, dot_calls = 0 }
    attach(self, logger)
    if type(runtime_lib) ~= 'table' or type(runtime_lib.shared) ~= 'function' then
        self.reason = 'bingus_runtime copy missing'
        return self
    end
    if type(memory_lib) ~= 'table' or type(memory_lib.new) ~= 'function' then
        self.reason = 'bingus_memory copy missing'
        return self
    end
    local ok, api = pcall(memory_lib.new, runtime_lib)
    if not ok then
        self.reason = tostring(api)
        return self
    end
    if type(api) ~= 'table' or type(api.read) ~= 'function' then
        self.reason = 'bingus_memory returned no api'
        return self
    end
    self.api = api
    return self
end

return memory
