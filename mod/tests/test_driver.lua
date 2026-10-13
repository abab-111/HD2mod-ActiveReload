-- 帧驱动接线的行为面用例（必须真实调用宿主每帧链，不直调被测面）。
-- 驱动链＝真驱动件 ＋ 真随包运行时件；只桩宿主 update/shutdown 与日志出口，观测转发顺序与失败语义。
-- 覆盖八件事：①宿主 update 已被替换；②我方帧每帧一次且先于原 update；③原 update 收到原参数、返回值透传；
-- ④原 update 抛错时错误原样到达调用方；⑤我方帧抛错被计数、达上限即停止并落停止行、此后不再驱动我方帧；
-- ⑥宿主没有 update 时 attach 回 false,'update-missing' 且不抛；⑦首帧 dt 行确实产出；⑧心跳行按配置间隔落出。

return function(env)
    local driver_lib = env.modules['game/driver']
    local runtime_lib = env.modules['game/vendor/bingus_runtime']
    local log_lib = env.modules['log']
    local config_lib = env.modules['config']
    env.check(type(driver_lib) == 'table', '驱动件在用例环境里可加载')
    env.check(type(runtime_lib) == 'table', '随包运行时件在用例环境里可加载')

    local lines = {}
    local logger = log_lib.new({ level = 'info', prefix = '' },
                               function(line) lines[#lines + 1] = line end)

    local function clear()
        for index = #lines, 1, -1 do lines[index] = nil end
    end

    local function saw(text)
        for index = 1, #lines do
            if string.find(lines[index], text, 1, true) ~= nil then return true end
        end
        return false
    end

    -- 假宿主：update/shutdown 为桩；host_error 置真时原 update 抛错，frame_error 置真时我方帧抛错。
    local function build()
        local host = { trace = {}, frames = 0 }
        host.env = {
            update = function(...)
                host.trace[#host.trace + 1] = 'update'
                host.args = { ... }
                if host.host_error then error('host boom', 0) end
                return 'host-ok'
            end,
            shutdown = function() host.trace[#host.trace + 1] = 'shutdown' end,
        }
        host.modules = { ['log'] = log_lib, ['game/vendor/bingus_runtime'] = runtime_lib }
        host.driver = driver_lib.new({
            modules = host.modules, logger = logger, config = config_lib,
            frame = function(delta)
                host.trace[#host.trace + 1] = 'frame'
                host.frames = host.frames + 1
                if host.frame_error then error('frame boom', 0) end
                return delta
            end,
            env = host.env,
        })
        return host
    end

    -- 一、正常宿主：接线成功、顺序正确、参数与返回值透传、首帧行落出。
    local host = build()
    local original = host.env.update
    local made, reason = driver_lib.attach(host.driver)
    env.check(made == true and reason == 'attached', '正常宿主下 attach 成功')
    env.check(host.env.update ~= original, '①宿主 update 已被替换')
    env.check(saw('DRIVER status=attached name=active_reload'), '接线成功行具名')
    env.check(not saw('DRIVER status=skipped'), '接线成功时不落跳过行')

    local result = host.env.update(1 / 45, 'x')
    env.check(#host.trace == 2 and host.trace[1] == 'frame' and host.trace[2] == 'update',
              '②我方帧每帧一次且先于原 update')
    env.near(host.args[1], 1 / 45, 0.000001, '③原 update 收到原参数 dt')
    env.equal(host.args[2], 'x', '③原 update 收到原参数 tag')
    env.equal(result, 'host-ok', '③原 update 的返回值透传')
    env.check(saw('DRIVER first-frame dt='), '⑦首帧 dt 行产出')
    env.check(not saw('DRIVER frames='), '首帧只落首帧行，未到心跳间隔不落心跳行')

    for _ = 1, 4 do host.env.update(1 / 45, 'x') end
    env.equal(host.frames, 5, '②多帧调用一帧一次，无重复驱动')
    env.equal(#host.trace, 10, '②五帧共十次记录（帧与宿主各半）')

    -- 二、重复接线：同一实例二次 attach 即具名跳过，不触碰宿主 update。
    local again_env = build()
    driver_lib.attach(again_env.driver)
    local hooked = again_env.env.update
    local twice, twice_reason = driver_lib.attach(again_env.driver)
    env.check(twice == false and twice_reason == 'already-installed', '二次 attach 回 already-installed')
    env.check(again_env.env.update == hooked, '二次 attach 不改宿主 update')
    env.check(saw('DRIVER status=skipped reason=already-installed'), '二次 attach 落具名跳过行')

    -- 三、原 update 抛错：错误原样到达调用方，我方帧照旧先跑。
    local raising = build()
    driver_lib.attach(raising.driver)
    raising.host_error = true
    raising.trace = {}
    local raised, raised_text = pcall(raising.env.update, 1 / 45, 'x')
    env.check(raised == false and string.find(tostring(raised_text), 'host boom', 1, true) ~= nil,
              '④原 update 的错误原样到达调用方')
    env.check(raising.trace[1] == 'frame' and #raising.trace == 2, '④宿主抛错前我方帧已跑')

    -- 四、我方帧连续抛错：守卫计数到上限即停止，落停止行，此后不再驱动我方帧。
    local broken = build()
    clear()
    driver_lib.attach(broken.driver)
    broken.frame_error = true
    for _ = 1, 8 do broken.env.update(1 / 45) end
    local status = runtime_lib.shared(broken.env).statuses['active_reload']
    env.check(type(status) == 'table', '守卫状态表在会话共享表里登记')
    env.equal(status.errors, 8, '⑤我方帧连续出错计数到上限')
    env.check(string.sub(tostring(status.state), 1, 8) == 'stopped:', '⑤达上限即停止态')
    env.check(saw('DRIVER status=stopped reason='), '⑤停止行落出')
    local frozen = broken.frames
    broken.env.update(1 / 45)
    env.equal(broken.frames, frozen, '⑤停止后不再驱动我方帧')

    -- 五、宿主没有 update：attach 不抛，回具名失败语义，不替换任何东西。
    local bare = { shutdown = function() end }
    local bare_driver = driver_lib.new({
        modules = { ['log'] = log_lib, ['game/vendor/bingus_runtime'] = runtime_lib },
        logger = logger, config = config_lib, frame = function() return nil end, env = bare,
    })
    clear()
    local bare_ok, bare_made, bare_reason = pcall(driver_lib.attach, bare_driver)
    env.check(bare_ok == true, '⑥宿主缺 update 时 attach 不抛')
    env.check(bare_made == false and bare_reason == 'update-missing', '⑥attach 回 update-missing')
    env.check(saw('DRIVER status=skipped reason=update-missing'), '⑥跳过行具名')
    env.equal(rawget(bare, 'update'), nil, '⑥失败路径不往宿主写入 update')

    -- 六、无随包运行时件：attach 回 no-runtime，不抛。
    local orphan = driver_lib.new({
        modules = { ['log'] = log_lib }, logger = logger, config = config_lib,
        frame = function() return nil end, env = { update = function() end },
    })
    local orphan_ok, orphan_made, orphan_reason = pcall(driver_lib.attach, orphan)
    env.check(orphan_ok == true, '无运行时件时 attach 不抛')
    env.check(orphan_made == false and orphan_reason == 'no-runtime', '无运行时件回 no-runtime')

    -- 七、缺帧函数：构造即回 no-frame。
    local none, none_reason = driver_lib.new({ modules = host.modules, logger = logger, config = config_lib })
    env.check(none == nil and none_reason == 'no-frame', '缺帧函数时构造回 no-frame')

    -- 八、心跳：按 config.driver.heartbeat_frames 落一行存活读数（存活面，不进任何判据）。
    local beating = build()
    clear()
    driver_lib.attach(beating.driver)
    for _ = 1, config_lib.driver.heartbeat_frames do beating.env.update(1 / 45) end
    env.equal(beating.frames, config_lib.driver.heartbeat_frames, '⑧心跳间隔帧数已驱动到位')
    env.check(saw('DRIVER frames=' .. tostring(config_lib.driver.heartbeat_frames)), '⑧心跳行按配置间隔落出')
    env.check(not saw('DRIVER status=stopped'), '⑧正常运行不落停止行')

    -- 九、入口装配面：真入口 + 真驱动 + 真守卫，宿主每帧链被接上并被真实调用一次。
    local previous_modules = rawget(_G, 'modules')
    local previous_update = rawget(_G, 'update')
    local previous_shutdown = rawget(_G, 'shutdown')
    local previous_loader = rawget(_G, 'CowboyBingusModLoader')
    local host_args = {}
    clear()
    rawset(_G, 'modules', env.modules)
    rawset(_G, 'CowboyBingusModLoader', nil)
    rawset(_G, 'update', function(delta, tag) host_args[#host_args + 1] = tag return 'host-ok' end)
    local entry_ok, system = pcall(env.entry)
    env.check(entry_ok == true and type(system) == 'table', '⑨宿主链在场时入口装配成功')
    env.check(type(system) == 'table' and type(system.driver) == 'table', '⑨装配后系统对象带驱动件')
    env.equal(type(system) == 'table' and system.driver.attached, true, '⑨入口尾把系统挂上宿主链')
    env.check(type(rawget(_G, 'update')) == 'function' and rawget(_G, 'update') ~= nil,
              '⑨宿主链上的更新函数已由守卫接管')
    env.equal(type(system) == 'table' and system.driver.frames, 0, '⑨接管发生在装配期，尚未跑帧')
    local forwarded = _G.update(1 / 45, 'ping')
    env.equal(forwarded, 'host-ok', '⑨经宿主链调用后原更新函数返回值透传')
    env.equal(system.driver.frames, 1, '⑨宿主每帧链真的驱动了系统帧函数')
    env.equal(host_args[1], 'ping', '⑨原更新函数收到宿主原样参数')
    -- 用例自身隔离：把宿主全局链与守卫登记还原，免影响后续用例文件
    rawset(_G, 'update', previous_update)
    rawset(_G, 'shutdown', previous_shutdown)
    rawset(_G, 'modules', previous_modules)
    rawset(_G, 'CowboyBingusModLoader', previous_loader)
    pcall(function() runtime_lib.shared(_G).statuses['active_reload'] = nil end)

    -- 十、帧成本量测（门内测量，只报告不入判据）：守卫包装后每帧一次的开销，对照每帧 ≤0.02 ms。
    local bench = build()
    driver_lib.attach(bench.driver)
    local rounds = 200000
    local started_at = os.clock()
    for step_index = 1, rounds do
        bench.env.update(1 / 45)
        if step_index % 20000 == 0 then bench.trace = {} end
    end
    local spent = os.clock() - started_at
    local per_frame_ms = spent * 1000 / rounds
    print(string.format('FRAME COST rounds=%d total=%.4f s ms_per_frame=%.6f', rounds, spent, per_frame_ms))
    env.equal(bench.frames, rounds, '⑩量测期间每帧都被驱动一次')

    -- 十一、诊断面纪律：链不可解析时，由宿主每帧链驱动出来的帧路径也不落诊断行
    -- （不落常量行、不以 0 冒充读数）；正向一行（链解析成功时只落一次）由 test_readface.lua 见证。
    pcall(function() runtime_lib.shared(_G).statuses['active_reload'] = nil end)
    clear()
    rawset(_G, 'modules', env.modules)
    rawset(_G, 'CowboyBingusModLoader', nil)
    rawset(_G, 'update', function(delta, tag) return 'host-ok' end)
    local probe_ok, probe_system = pcall(env.entry)
    env.check(probe_ok == true and type(probe_system) == 'table', '⑪宿主链在场时入口装配成功（诊断面在场）')
    if type(probe_system) == 'table' then
        clear()
        _G.update(1 / 45, 'probe')
        env.check(not saw('READFACE '), '⑪链不可解析时零诊断行（不落常量行、不以 0 冒充读数）')
    end
    rawset(_G, 'update', previous_update)
    rawset(_G, 'modules', previous_modules)
    rawset(_G, 'CowboyBingusModLoader', previous_loader)
    pcall(function() runtime_lib.shared(_G).statuses['active_reload'] = nil end)
end
