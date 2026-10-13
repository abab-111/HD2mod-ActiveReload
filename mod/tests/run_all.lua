-- 自测入口：宿主（tests/compile_check.py）把源码以函数体形式内联成下列值后再加载本文件：
--   __sources[相对路径] = function() ... end   返回该模块
--   __entry            = function() ... end   执行入口，调用前需要把全局 modules 指向模块表
--   __cases[i]         = { name = 用例名, body = function() ... end }   body 接收执行环境
-- 汇报写入全局 __report；没有注入时退回 print。返回失败项数量。

local report = rawget(_G, '__report') or print
local sources = rawget(_G, '__sources') or {}
local cases = rawget(_G, '__cases') or {}

local env = {
    entry = rawget(_G, '__entry'),
    modules = {},
    passed = 0,
    failed = 0,
}

function env.check(condition, message)
    if condition then
        env.passed = env.passed + 1
        return true
    end
    env.failed = env.failed + 1
    report('FAIL: ' .. tostring(message))
    return false
end

function env.equal(actual, expected, message)
    return env.check(actual == expected,
                     message .. '（实际 ' .. tostring(actual) .. '，期望 ' .. tostring(expected) .. '）')
end

function env.near(actual, expected, tolerance, message)
    local matched = type(actual) == 'number' and math.abs(actual - expected) <= tolerance
    return env.check(matched,
                     message .. '（实际 ' .. tostring(actual) .. '，期望 ' .. tostring(expected) .. '）')
end

local paths = {}
for path in pairs(sources) do
    paths[#paths + 1] = path
end
table.sort(paths)

for index = 1, #paths do
    local path = paths[index]
    local ok, module = pcall(sources[path])
    if not ok then
        env.failed = env.failed + 1
        report('FAIL: 无法加载模块 ' .. path .. '：' .. tostring(module))
    elseif type(module) ~= 'table' then
        env.failed = env.failed + 1
        report('FAIL: 模块未返回表 ' .. path)
    else
        local key = path:sub(-4) == '.lua' and path:sub(1, -5) or path
        env.modules[key] = module
    end
end

for index = 1, #cases do
    local case = cases[index]
    local loaded, body = pcall(case.body)
    if not loaded then
        env.failed = env.failed + 1
        report('FAIL: 无法加载用例 ' .. tostring(case.name) .. '：' .. tostring(body))
    else
        local ran, failure = pcall(body, env)
        if ran then
            report('ok: ' .. tostring(case.name))
        else
            env.failed = env.failed + 1
            report('FAIL: ' .. tostring(case.name) .. ' 中断：' .. tostring(failure))
        end
    end
end

report(string.format('TOTAL passed=%d failed=%d', env.passed, env.failed))
return env.failed
