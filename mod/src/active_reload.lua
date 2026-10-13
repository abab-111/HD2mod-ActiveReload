-- HD2-Addon: mods/hd2mod/active_reload
--
-- 入口：从构建脚本注入的模块表取出各模块，注入依赖后装配成一个可驱动的系统对象。
-- 模块表在组装后的资源里由构建脚本绑定为局部名 modules，含 src/ 下各模块与一个 build 元数据模块
-- （提供 resource、version、guid）；单独取出本文件做语法检查时该值为 nil。
--
-- 启动：加载器在场时把启动交给 after_startup，由加载器在首个更新帧之前调用一次；
-- 没有加载器时入口自行启动一次，便于脱离游戏做装配检查。启动只生效一次。
--
-- 集成面（system.driver 把本系统挂到宿主每帧链，装配完成后自动接线）：
--   system.activate()          启动入口，只能成功一次
--   system.begin(seconds)      开始一轮，seconds 为本轮基础时长，省略时用兜底时长；返回区间起点与终点
--   system.step(delta)         推进一轮，delta 为秒（计时只由 frame 的喂钟供给，本函数不读时钟）
--   system.frame(delta)        一帧的完整次序：喂钟 → 取快照 → 窗口判定 → 打断判定 → 采样按键 → 上报判定 → 推进一轮
--   system.press()             上报一次重装键按下，返回 hit、miss 或 ignored
--   system.sample()            读取按键边沿，返回是否触发、是否松开与电平读不到时的具名原因
--   system.draw(sink, screen)  绘制完成度条；system.paint() 为整帧绘制入口（窗口内提交、命中或窗关清面）
--   system.settings            当前设置取值
--   system.options             可调项声明列表
--   system.input_echo          装配期取源回显（INPUT source=… spec=…）
--   system.observed            只读登记：打断两候选与静音窗自证（只观测，不进任何判据）
--
-- 装配成功时返回系统对象（与生态中「入口转发实现资源」的写法一致）；模块表缺失时返回 nil。

local modules = modules

local function assemble()
    if type(modules) ~= 'table' then
        return nil
    end
    local config = modules['config']
    local log = modules['log']
    local options = modules['options']
    local zone = modules['core/zone']
    local timeline = modules['core/timeline']
    local state = modules['core/state']
    local reload = modules['game/reload']
    local input = modules['game/input']
    local time = modules['game/time']
    local bar = modules['ui/bar']
    local metadata = modules['build']

    if type(metadata) ~= 'table' then
        return nil
    end

    local settings = options.resolve(config.options, nil)
    local cycle = state.new({
        rng = function() return math.random() end,
        zone = config.zone,
        cycle = {
            fallback_seconds = config.cycle.fallback_seconds,
            sweep_start = config.cycle.sweep_start,
            penalty_per_miss = settings.penalty_percent,
        },
        pick_zone = zone.pick,
        hit = zone.hit,
        position_at = timeline.position,
        duration_of = timeline.duration,
    })

    -- 日志出口：授权构型（日志端点件在场）接加载器文件端点，默认构型不含该件 ⇒ 出口与现状逐字一致。
    local log_sink = (type(modules) == 'table' and type(modules['game/logsink']) == 'table')
        and modules['game/logsink'].open(config.log) or nil
    local logger = log.new(config.log, log_sink)
    -- 时钟：帧驱动累加（暂停不产帧即冻结）。注入给 time.new 的是读取函数，取不到数时读接口返回 nil。
    local ticker = time.stepper(config.clock.max_step)
    local clock = time.new(function() return time.read(ticker) end)
    local chord = input.new(nil, config.cycle)
    -- 读取面：模块表只负责造实例（memory.new 四参＝读取面运行时、随包内存件、日志器、可执行名），
    -- 守卫看实例自身（available 冒号调用）；实例或适配器缺失即保持 nil，读接口返 nil 与具名原因。
    local access = nil
    local access_lib = modules['game/access']
    local memory_lib = modules['game/memory']
    local mem = nil
    if type(memory_lib) == 'table' and type(memory_lib.new) == 'function' then
        mem = memory_lib.new(modules['game/vendor/bingus_runtime'],
                             modules['game/vendor/bingus_memory'], logger, 'helldivers2.exe')
    end
    if type(access_lib) == 'table' and type(access_lib.new) == 'function' and
       type(mem) == 'table' and type(mem.available) == 'function' and mem:available() == true then
        -- 拿不到数字基址即读面不可用（set_game(nil) 会把 game 落成表值，读址必炸）
        local base = type(mem.module_base) == 'function' and mem:module_base('game.dll') or nil
        if type(base) == 'number' then
            access = access_lib.new(mem, config)
            access:set_game(base)
            -- 时钟挂在读取面上（reload 契约里 now() 属读取面）：帧驱动时钟，暂停不产帧即冻结
            access.now = function() return time.read(ticker) end
        end
    end
    -- 取源装配（三级链；唯一实现路径 input.native）：拿不到就退回维持原生读取，
    -- 电平恒 nil（不进边沿、不消耗判定、不惩罚），并如实落具名原因，绝不静默。
    local inputs = config.inputs
    local input_lib = modules['game/input']
    local input_level, input_reason = nil, 'source-missing'
    if type(access) == 'table' and type(input_lib) == 'table' and
       type(input_lib.native) == 'function' then
        input_level, input_reason = input_lib.native(access, inputs, modules)
    end
    if input_level == nil then
        input_reason = input_reason or 'source-missing'
        log.info(logger, 'INPUT source=missing reason=' .. tostring(input_reason))
        input_level = function() return nil, input_reason end
    end
    local trigger = reload.new(nil, access)
    -- 装配回显：源名与规格指纹取自 config，比对基准在测试里写成字面常量（禁自比）。
    local input_echo = 'INPUT source=' .. tostring(inputs and inputs.source) ..
        ' spec=' .. tostring(inputs and inputs.form_b_fingerprint)
    log.info(logger, input_echo)
    log.info(logger, 'SYSTEM game_base=' .. (type(access) == 'table' and
        type(access.game) == 'number' and '0x' .. string.format('%x', access.game) or 'none'))
    -- 采样器读一次即留本帧副本：电平读不到时必须带具名原因（H3），帧路径零新建闭包。
    local source = input_level
    local last_down, last_why = nil, nil
    local function sample_source()
        local down, why = source()
        last_down, last_why = down, why
        return down
    end
    chord.sample = sample_source
    local started, frame_index = false, 0
    local last_slot, last_baseline, interrupted = nil, nil, false
    local was_window, opened_running, opened_stage = false, false, 0   -- 窗口首帧两路读数（只登记）
    local seen = 0                    -- 本窗口电平：0 未读、1 仅假、2 见过真；nil 属读不到，不计静音
    local mute_windows = config.inputs.form_b.mute_windows   -- 静音窗自证阈值（config 唯一来源）
    local observed = { ability = false, stage = false, mute = 0, mute_reported = false }
    -- 绘制端：把条挂到引擎的屏幕 GUI 上；宿主没暴露绘制面时只落一行具名原因，不影响其它面。
    local surface = bar.sink({ env = _G, layer = config.bar.layer, note = function(line) log.info(logger, line) end })
    local gate = bar.hold(config.bar.hold_seconds)   -- 显示门状态：短窗延续（三段合一）＋写入锁存抑制
    -- 闸门 A-2：默认构建不含 game/wiring.lua，此支永不进入 ⇒ 闸门维持假、send 逐字回 false,'disabled'。
    local wiring = nil
    trigger.instant_enabled = false
    if type(modules) == 'table' and modules['game/instant'] ~= nil and modules['game/wiring'] ~= nil then
        wiring = modules['game/wiring'].new({ modules = modules, config = config, logger = logger,
                                              access = access, trigger = trigger, observed = observed })
        trigger.instant_enabled = type(wiring) == 'table' and wiring.gate == true
    end
    local system = {
        settings = settings,
        options = options.describe(config.options),
        input_echo = input_echo,
        input_reason = input_reason,
        observed = observed,
    }
    local driver_lib = modules['game/driver']
    system.driver = driver_lib ~= nil and driver_lib.new({ modules = modules, logger = logger, config = config,
        frame = function(delta) return system.frame(delta) end,
        paint = function() return system.paint() end }) or nil

    function system.activate()
        if started then
            return false
        end
        started = true
        log.info(logger, 'loaded ' .. metadata.resource .. ' v' .. metadata.version)
        options.bind(config.options, settings, { env = _G, note = function(line) log.info(logger, line) end })
        return true
    end

    function system.begin(seconds)
        if not started then
            return nil
        end
        state.begin(cycle, seconds)
        return cycle.zone_start, cycle.zone_finish
    end

    -- 计时唯一来源是 frame 里的喂钟；本函数只推进状态机（非数字或不合法数字视作不推进）。
    function system.step(delta)
        if not started then
            return nil
        end
        if type(delta) == 'number' and delta == delta then
            state.advance(cycle, delta)
        end
        return cycle.phase
    end

    function system.press()
        if not started then
            return nil
        end
        local result = state.press(cycle)
        if result == 'hit' then
            local sent, note = reload.send(trigger)
            log.debug(logger, 'complete ' .. tostring(sent) .. ' ' .. tostring(note))
        end
        return result
    end

    -- 采样：边沿给状态机、电平给面板；本帧电平读不到时第三个回值给出具名原因（不用 false 冒充）。
    function system.sample()
        if not started then
            return false, true
        end
        local pressed, released = input.poll(chord)
        if last_down ~= nil then
            released = last_down ~= true
        end
        return pressed and true or false, released, last_why
    end

    -- 一帧的完整次序：喂钟 → 取快照 → 窗口判定 → 打断判定 → 采样按键 → 上报判定 → 推进一轮。
    -- 读不到快照时不做任何判定（读失败不猜值）；窗口外按键不惩罚、不消耗判定、不改本轮、不触写路径。
    -- 映射失效与「换槽打断」都不算换弹结束；两条打断候选只登记观测，不进任何判据。
    function system.frame(delta)
        if not started then
            return nil
        end
        frame_index = frame_index + 1
        time.feed(ticker, delta)
        local snap = reload.snapshot(trigger, frame_index)
        local open = reload.window(trigger, snap)
        local in_window = open == true
        -- 窗口边沿：开窗记两路读数；关窗结算静音窗（整窗无真电平＋至少一次明确假电平，nil 不计）。
        local was = was_window
        was_window = in_window
        cycle.window = bar.gate(gate, in_window, type(ticker) == 'table' and ticker.seconds or nil, wiring ~= nil and wiring.latched == true)   -- 显示窗口＝真实窗口经延续与锁存过滤
        if snap ~= nil and in_window then
            if not was then
                opened_running, opened_stage = snap.ability_running == true, snap.reload_stage
            elseif opened_running and snap.ability_running ~= true then
                observed.ability = true
            elseif opened_stage ~= 0 and snap.reload_stage == 0 then
                observed.stage = true
            end
        end
        if was and not in_window then
            if seen == 1 then observed.mute = observed.mute + 1 end
            if observed.mute == mute_windows and observed.mute_reported ~= true then
                observed.mute_reported = true
                log.info(logger, 'INPUT-B-MUTE windows=' .. tostring(observed.mute))
            end
            seen = 0
        end
        if snap ~= nil then
            if snap.reloading and last_slot ~= nil and snap.weapon_entity ~= last_slot then
                interrupted = true
            end
            local event = reload.edge(trigger, snap)
            if event == 'start' then
                state.begin(cycle, last_baseline)
            elseif event == 'end' then
                local measured = reload.duration(trigger, snap)
                if type(measured) == 'number' then
                    last_baseline = measured
                end
                if interrupted then
                    state.interrupt(cycle)
                    interrupted = false
                end
            end
            last_slot = snap.weapon_entity
        end
        local pressed = system.sample()
        if wiring ~= nil then
            wiring.track(wiring, snap, in_window, was, pressed, ticker)
        end
        -- 静音窗自证只统计窗口内的明确电平（1＝仅假、2＝出现过真）；nil 属读不到，不计入静音。
        if in_window and last_down ~= nil then
            if last_down == true then seen = 2 elseif seen == 0 then seen = 1 end
        end
        if in_window and pressed then
            system.press()
        end
        return system.step(delta)
    end

    -- 绘制一帧：窗口内提交，命中或窗关清面（回调在装配期建一次，帧路径不新建闭包）。
    local function paint(screen) return system.draw(surface, screen) end
    function system.paint()
        return bar.render(surface, cycle, state.SWEEP, paint)
    end

    function system.draw(sink, screen)
        if not started or type(screen) ~= 'table' then
            return false
        end
        local view = { width = settings.bar_width, thickness = settings.bar_thickness, offset = settings.bar_offset }
        local layout = bar.layout(screen, config.bar, view,
                                  cycle.position, cycle.zone_start, cycle.zone_finish)
        return bar.draw(sink, layout, bar.palette(config.color, cycle.misses), config.bar.border)
    end

    return system
end

local system = assemble()

if system then
    local loader = rawget(_G, 'CowboyBingusModLoader')
    if type(loader) == 'table' and type(loader.after_startup) == 'function' then
        loader.after_startup(function() system.activate() end)
    else
        system.activate()
    end
    if system.driver ~= nil then system.driver.attach(system.driver) end
end

return system
