-- 桩用例（不是门，见 mod/tests/README 角色表）：读面底座的地址域归一、失败面与写方法缺席。
return function(env)
    local memory = env.modules['game/memory']
    if not (type(memory) == 'table' and type(memory.new) == 'function') then
        env.check(false, 'game/memory 模块未加载')
        return
    end

    local errors = {}
    local logger = { error = function(_, text) errors[#errors + 1] = text end }

    -- 桩 api：全部按点调用受参（memory.lua 内部一律点调用 api.*）。
    local seen = {}
    local api = {
        module = function(name)
            seen.module = name
            if seen.module_nil_ok and name == nil then return 'HANDLE-NIL' end
            if name == 'game.dll' then return 'HANDLE' end
            return nil
        end,
        address = function(value) seen.address = value return 16777216 end,
        pointer = function(_, offset) seen.offset = offset return 'PTR:' .. tostring(offset) end,
        read = function(address, size)
            seen.read = { address, size }
            if seen.fail then return nil end
            return string.rep('x', size)
        end,
    }
    local runtime = { shared = function() return {} end }
    local lib = { new = function() return api end }

    local object = memory.new(runtime, lib, logger, 'game.dll')
    env.check(type(object) == 'table', 'memory.new 应返回对象')
    env.equal(object:available(), true, '装好依赖后 available 应为真')
    env.equal(object:reason_text(), nil, '成功接线后不应有原因')

    -- 交出方向：有 ffi 时 number 必须 cast 成 const void * 再交给 api.read。
    seen.cast = nil
    api.windows = { ffi = { cast = function(kind, value) seen.cast = { kind, value } return 'CDATA' end } }
    local text = object:read(4096, 32)
    env.equal(#text, 32, 'read 应原样回传 api.read 的字符串')
    env.equal(seen.cast[1], 'const void *', '交出方向必须 cast 成 const void *')
    env.equal(seen.cast[2], 4096, 'cast 的实参应是原地址数字')
    env.equal(seen.read[1], 'CDATA', 'api.read 应收到归一化后的指针，而不是裸 number')
    env.equal(seen.read[2], 32, 'read 宽度应原样透传')

    -- 无 ffi 时原样透传（L1 无 LuaJIT 的可观测面）。
    api.windows = nil
    object:read(8192, 16)
    env.equal(seen.read[1], 8192, '无 ffi 面时交出方向原样透传 number')

    -- 收回方向：api.pointer 的返回值必须过 api.address 折成 Lua 数字。
    local folded = object:pointer('blob', 4)
    env.equal(type(folded), 'number', 'pointer 必须折成 Lua 数字（收回方向归一）')
    env.equal(folded, 16777216, 'pointer 返回值应等于 api.address 的结果')
    env.equal(seen.address, 'PTR:4', 'api.address 应收到 api.pointer 的原始返回值')

    -- 模块基址：按名字取，取不到且名字等于可执行名时回落到无名模块。
    env.equal(object:module_base('game.dll'), 16777216, 'module_base 应折成数字')
    env.equal(object:module_base('other.dll'), nil, '取不到的模块应回 nil')

    -- 读失败：nil 必须原样返回并计数，不静默、不以空串冒充。
    seen.fail = true
    local before = object:stats().failures
    env.equal(object:read(4096, 8), nil, '读失败应回 nil')
    env.equal(object:stats().failures, before + 1, '读失败应计入 failures')
    seen.fail = nil

    -- 缺依赖三态：各自有原因串，且读面保持不可用（不抛异常）。
    env.equal(memory.new(nil, lib, logger).reason, 'bingus_runtime copy missing', '缺运行时副本应有原因')
    env.equal(memory.new(runtime, nil, logger).reason, 'bingus_memory copy missing', '缺适配副本应有原因')
    env.equal(memory.new(runtime, { new = function() return {} end }, logger).reason,
              'bingus_memory returned no api', 'api 不成形应有原因')
    local bare = memory.new(nil, nil, logger)
    env.equal(bare:available(), false, '缺依赖时 available 应为假')
    env.equal(bare:read(4096, 8), nil, '缺依赖时 read 应回 nil')

    -- 点调用守卫：地址被吃成 self 是已证的静默降级形态，必须计数并记日志。
    local call_count = object:stats().dot_calls
    env.equal(object.read(4096, 8), nil, '点调用应回 nil 而不是读地址 4096')
    env.equal(object:stats().dot_calls, call_count + 1, '点调用应计入 dot_calls')
    env.equal(#errors, 1, '点调用应记一行日志')

    -- 写面缺席：本文件对外面里不得出现任何写方法。
    env.check(object.write == nil and object.write_batch == nil, '读面对象不得暴露写方法')
    env.check(memory.write == nil and memory.write_batch == nil and memory.read_bytes == nil,
              '读面模块表不得暴露写方法与内部助手')
end
