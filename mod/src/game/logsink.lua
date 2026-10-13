-- 日志文件端点（授权包独有的装配件）：把产品日志接到共享加载器的日志文件。
-- 本件只做出口：装配期尝试打开端点，拿不到就返回 nil，由调用方回退到控制台输出，绝不中断装配。
-- 打开成功时返回逐行写入函数，且首行先写一行端点状态行——判读时据此区分「没有观测」与「没有活动」。
-- 依赖注入：只用设置表与加载器全局，不直接访问游戏；本件不含任何写路径调用。

local logsink = {}

-- 名称契约与加载器一致：字母、数字、下划线、短横，扩展名固定 .log，不含目录分隔符。
local NAME_PATTERN = '^[%w_-]+%.log$'

-- 端点统计：写入失败只累计计数，不抛异常（日志出口不得影响帧路径）。
logsink.stats = { dropped = 0, primed = false }

-- 打开端点：成功返回逐行写入函数，失败返回 nil 与原因标签（调用方回退控制台）。
function logsink.open(settings)
    local name = nil
    if type(settings) == 'table' then
        name = settings.name
    end
    if type(name) ~= 'string' or name:match(NAME_PATTERN) == nil then
        return nil, 'no-name'
    end
    local loader = rawget(_G, 'CowboyBingusModLoader')
    if type(loader) ~= 'table' or type(loader.open_log) ~= 'function' then
        return nil, 'no-loader'
    end
    local opened, handle = pcall(loader.open_log, name)
    if opened ~= true or handle == nil then
        return nil, 'no-handle'
    end
    local state = logsink.stats
    state.dropped, state.primed = 0, false
    return function(message)
        local text = tostring(message)
        if state.primed ~= true then
            state.primed = true
            text = 'LOG sink=file name=' .. name .. '\n' .. text
        end
        -- 逐行写入并立即冲刷：异常退出时已写出的行不丢。
        local ok = pcall(function()
            handle:write(text .. '\n')
            handle:flush()
        end)
        if ok ~= true then
            state.dropped = state.dropped + 1
        end
    end
end

return logsink
