-- 入口装配：模块表注入、启动、设置取值、显式推进、判定、绘制提交

return function(env)
    local entry = env.entry
    env.check(type(entry) == 'function', '宿主已提供入口源码')
    if type(entry) ~= 'function' then
        return
    end

    local previous_modules = rawget(_G, 'modules')
    local previous_loader = rawget(_G, 'CowboyBingusModLoader')
    rawset(_G, 'modules', env.modules)
    rawset(_G, 'CowboyBingusModLoader', nil)

    -- 回显捕获：日志默认端会写到标准输出，这里换成收集器（禁自比：期望值一律写字面常量）
    local said = {}
    local real_print = _G.print
    _G.print = function(...)
        local parts = {}
        for index = 1, select('#', ...) do
            parts[#parts + 1] = tostring((select(index, ...)))
        end
        said[#said + 1] = table.concat(parts, ' ')
    end
    local function saw(text)
        for index = 1, #said do
            if string.find(said[index], text, 1, true) ~= nil then
                return true
            end
        end
        return false
    end

    -- 默认构建的模块表逐键在场（键名与 MODULE_ORDER 去掉 .lua 后一致）
    for _, key in ipairs({
        'config', 'log', 'options', 'core/zone', 'core/timeline', 'core/state',
        'game/reload', 'game/access', 'game/input', 'game/time', 'game/memory',
        'game/source_formb', 'game/vendor/bingus_runtime', 'game/vendor/bingus_memory',
        'ui/bar', 'build',
    }) do
        env.check(type(env.modules[key]) == 'table', '模块表在场：' .. key)
    end

    -- 包装状态模块以捕获本轮实例（不改产品面；帧次序与参数链断言都需要读到实例）
    local state_lib = env.modules['core/state']
    local cycle = nil
    env.modules['core/state'] = setmetatable({
        new = function(deps)
            cycle = state_lib.new(deps)
            return cycle
        end,
    }, { __index = state_lib })

    local ok, system = pcall(entry)
    env.check(ok, '入口执行不报错：' .. tostring(system))
    if not ok or type(system) ~= 'table' then
        env.check(false, '入口返回系统对象')
        rawset(_G, 'modules', previous_modules)
        rawset(_G, 'CowboyBingusModLoader', previous_loader)
        return
    end

    -- A1：装配期回显源名与规格指纹（基准为字面常量，禁自比）
    env.check(saw('INPUT source=form_b spec=8c041a6e'), '装配期回显取源与规格指纹')
    env.equal(system.input_echo, 'INPUT source=form_b spec=8c041a6e', '系统对象暴露同一条回显')
    local input_lib = env.modules['game/input']

    env.equal(system.activate(), false, '没有加载器时入口已自行启动，再次启动返回假')
    env.near(system.settings.bar_width, 0.25, 1e-12, '设置取默认条宽')
    env.near(system.settings.bar_thickness, 0.010, 1e-12, '设置取默认条厚')
    env.near(system.settings.bar_offset, 0.10, 1e-12, '设置取默认竖直偏移')
    env.near(system.settings.penalty_percent, 0.20, 1e-12, '设置取默认加时比例')
    env.equal(system.settings.language, 'auto', '设置取默认语言档（跟随游戏）')
    env.equal(#system.options, 5, '可调项声明为五条')
    env.equal(system.options[1].id, 'bar_offset', '可调项之一为竖直偏移')
    env.equal(system.options[2].id, 'bar_thickness', '可调项之二为条厚')
    env.equal(system.options[3].id, 'bar_width', '可调项之三为条宽')
    env.equal(system.options[4].id, 'language', '可调项之四为语言')
    env.equal(system.options[5].id, 'penalty_percent', '可调项之五为加时比例')

    -- 测试过程使用固定种子，运行时玩法随机不受此约束
    math.randomseed(20261005)
    local start, finish = system.begin()
    env.check(type(start) == 'number' and type(finish) == 'number', '开始一轮返回区间')
    env.check(finish > start, '区间终点在起点右侧')
    env.check(start >= 0.20 and start <= 0.50, '区间起点落在允许范围内')
    env.near(finish - start, 0.20, 1e-12, '区间宽度为条长的五分之一')

    system.frame(0)
    env.equal(state_lib.view(cycle).phase, 'sweep', '一帧之后仍处于扫过状态')
    env.equal(system.press(), 'miss', '扫过起点不在区间内，判定为按错')
    env.equal(system.press(), 'ignored', '同一轮内不再接受判定')

    local pressed, released = system.sample()
    env.equal(pressed, false, '未注入按键来源时不产生触发')
    env.equal(released, true, '未注入按键来源时按松开处理')

    -- 帧次序是唯一计时来源：喂钟与推进都在 frame 内，相位一律从只读视图读
    system.begin(1.0)
    env.equal(system.frame(0.5), 'sweep', '帧推进半程仍返回扫过相位')
    env.equal(state_lib.view(cycle).phase, 'sweep', '给出本轮时长后帧推进半程仍在扫过状态')
    env.equal(state_lib.view(cycle).window, false, '读不到快照时窗口标记为假')
    env.equal(system.frame(0.5), 'idle', '帧推进到本轮时长时本轮结束')
    env.equal(state_lib.view(cycle).phase, 'idle', '本轮结束由只读视图同步转出')
    system.begin(1.0)
    env.equal(system.step(0.5), 'sweep', '本函数只推进状态机，不再自行读钟')

    system.begin()
    local calls = {}
    local sink = {
        rect = function() calls[#calls + 1] = 'rect' end,
        frame = function() calls[#calls + 1] = 'frame' end,
    }
    local screen = { width = 1920, height = 1080 }
    env.equal(system.draw(sink, screen), true, '绘制提交成功')
    env.equal(#calls, 4, '绘制依次提交槽、区间、标记与外框')
    env.equal(calls[1], 'rect', '首个提交为填充矩形')
    env.equal(calls[4], 'frame', '末个提交为外框')
    env.equal(system.draw(nil, screen), false, '缺少绘制端时不提交')
    env.equal(system.draw(sink, nil), false, '缺少屏幕尺寸时不提交')

    local empty = {}
    env.equal(system.draw(empty, screen), true, '绘制端缺少方法时不报错')

    -- 绘制面状态机：接上桩引擎后，窗口内提交、命中即清面、窗关清面（端到端走 system.paint）
    local drawn, updated, screens = 0, 0, 0
    local engine = {
        Vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
        Vector2 = function(x, y) return { x = x, y = y } end,
        Color = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end,
        Gui = {
            resolution = function() return 1920, 1080 end,
            rect = function() drawn = drawn + 1 return { handle = drawn } end,
            update_rect = function() updated = updated + 1 end,
        },
        World = {
            create_screen_gui = function() screens = screens + 1 return { screen = true } end,
        },
        Application = {
            main_world = function() return 'main' end,
            worlds = function() return { 'main', 'mission' } end,
        },
    }
    local previous_stingray = rawget(_G, 'stingray')
    rawset(_G, 'stingray', engine)
    system.begin(1.0)
    cycle.window = true
    env.equal(system.paint(), true, '窗口内且本轮在扫过时提交绘制')
    env.equal(screens, 1, '绘制面按需取一次')
    env.equal(drawn, 7, '一帧共提交七个矩形（槽、命中区、游标与外框四边）')
    cycle.position = (cycle.zone_start + cycle.zone_finish) / 2
    env.equal(system.press(), 'hit', '游标移进命中区后判定为命中')
    env.equal(system.paint(), true, '命中后清面')
    env.equal(drawn, 7, '命中后不再新建矩形，改走更新')
    env.equal(updated, 7, '命中后把七个矩形全部收起')
    system.begin(1.0)
    cycle.window = false
    env.equal(system.paint(), true, '窗口外清面')
    env.equal(updated, 14, '窗口外再次把七个矩形收起')
    rawset(_G, 'stingray', previous_stingray)

    -- 用例 12：运行期直读设置表 —— 改设置后下一帧即生效（不重装入口、不新增刷新机制）
    system.settings.bar_width = 0.42
    local seen = nil
    local probe = {
        rect = function() end,
        frame = function(geometry)
            seen = geometry
        end,
    }
    system.begin()
    system.frame(0.016)
    env.equal(system.draw(probe, screen), true, '接上绘制端后返回真')
    env.near(seen.width, 1920 * 0.42, 1e-9, '下一帧的条宽取到改后的设置值')
    env.near(system.settings.bar_width, 0.42, 1e-12, '系统对象直接持有设置表，改动即时可见')
    env.near(system.options[3].default, 0.25, 1e-12, '可调项声明仍是装配期取到的默认值')

    local deferred = nil
    rawset(_G, 'CowboyBingusModLoader', {
        after_startup = function(callback) deferred = callback end,
    })
    local loaded, second = pcall(entry)
    env.check(loaded and type(second) == 'table', '加载器在场时入口仍返回系统对象')
    if type(second) == 'table' then
        env.equal(second.activate(), true, '启动交给加载器后可由调用方手动启动')
        env.equal(type(deferred), 'function', '入口在加载器的启动钩子上注册回调')
        if type(deferred) == 'function' then
            deferred()
            env.equal(second.activate(), false, '回调启动后不再重复启动')
        end
    end

    -- 读取面接线：注入内存接口与记录型读取面模块，核对入口把模块基址与时钟都挂上去了
    local recorder = { slots = function() return nil, 'no-entity' end }
    recorder.set_game = function(first, second)
        recorder.game = type(first) == 'table' and second or first
    end
    -- 内存实例：模块表只装 new；实例才带 available / module_base / read（一律冒号调用）。
    local mem = {
        available = function() return true end,
        read = function() return nil end,
        pointer = function() return nil end,
        module_base = function(self, name) return name == 'game.dll' and 0x1000000 or nil end,
    }
    local memory_lib = { new = function() return mem end }
    recorder.memory = mem
    local kept_access = env.modules['game/access']
    local kept_memory = env.modules['game/memory']
    env.modules['game/access'] = { new = function() return recorder end }
    env.modules['game/memory'] = memory_lib
    local wired, wired_system = pcall(entry)
    env.check(wired and type(wired_system) == 'table', '内存接口在场时入口仍能装配')
    if type(wired_system) == 'table' then
        wired_system.activate()
        env.equal(recorder.game, 0x1000000, '入口把模块基址交给读取面')
        env.check(type(recorder.now) == 'function', '入口把游戏侧时钟挂到读取面')
        wired_system.frame(0.5)
        env.near(recorder.now(), 0.5, 1e-9, '读取面的时钟随帧推进（暂停不产帧即冻结）')
        env.equal(wired_system.frame(0.25) ~= nil, true, '读取面在场时帧序照常推进')
        env.equal(wired_system.input_echo, 'INPUT source=form_b spec=8c041a6e',
                  '读取面在场时取源回显同一条基线')
        env.check(saw('SYSTEM game_base=0x1000000'), '装配期回显模块基址（桩内存返回字面 0x1000000）')
        local self_report = type(input_lib.block) == 'function' and input_lib.block(input_lib) or nil
        env.equal(self_report, 'form_b@8c041a6e', '取源自证等于源名加规格指纹')
    end
    env.modules['game/access'] = kept_access
    env.modules['game/memory'] = kept_memory

    -- 用例 1：取源缺线一律落具名原因，绝不以 false 静默冒充（每例换一个装配现场）
    local kept_formb = env.modules['game/source_formb']
    env.modules['game/source_formb'] = nil
    local miss_ok, miss_system = pcall(entry)
    env.check(miss_ok and type(miss_system) == 'table', '缺首选源模块时入口仍能装配')
    if type(miss_system) == 'table' then
        if type(deferred) == 'function' then
            deferred()
        end
        local pressed, released, why = miss_system.sample()
        env.equal(pressed, false, '缺源时按键电平不冒充按下')
        env.equal(released, true, '缺源时按键仍报松开')
        env.equal(why, 'source-missing', '缺源原因具名为 source-missing')
    end
    env.modules['game/source_formb'] = kept_formb

    said = {}
    local kept_memory_bare = env.modules['game/memory']
    env.modules['game/memory'] = nil
    local bare_ok, bare_system = pcall(entry)
    env.check(bare_ok and type(bare_system) == 'table', '缺内存接口时入口仍能装配')
    if type(bare_system) == 'table' then
        if type(deferred) == 'function' then
            deferred()
        end
        local pressed, _, why = bare_system.sample()
        env.equal(pressed, false, '没有读取面时按键电平恒为假')
        env.equal(why, 'source-missing', '没有读取面时原因具名为 source-missing')
        env.check(saw('INPUT source=missing'), '缺线时入口落一行具名回显')
    end
    env.modules['game/memory'] = kept_memory_bare

    -- B3：惩罚参数链 config 默认值 → 设置 → 状态机依赖，三处同值（用 0.37 非默认值注入）
    local chained = nil
    env.modules['core/state'] = setmetatable({
        new = function(deps)
            chained = state_lib.new(deps)
            return chained
        end,
    }, { __index = state_lib })
    local config_lib = env.modules['config']
    local kept_penalty = config_lib.options.penalty_percent.default
    config_lib.options.penalty_percent.default = 0.37
    local chained_ok, chained_system = pcall(entry)
    env.check(chained_ok and type(chained_system) == 'table', '非默认惩罚值时入口仍能装配')
    if chained_ok and type(chained_system) == 'table' then
        env.near(chained_system.settings.penalty_percent, 0.37, 1e-12, '设置取到 config 的默认值')
        env.near(chained.deps.cycle.penalty_per_miss, 0.37, 1e-12, '状态机依赖拿到同一份惩罚值')
    end
    config_lib.options.penalty_percent.default = kept_penalty
    env.modules['core/state'] = state_lib

    -- A5 负路径：实例在场但报读取面不可用 ⇒ 不构造读取面，回显降级到 source=missing
    local off_built = false
    local kept_memory_off = env.modules['game/memory']
    env.modules['game/access'] = { new = function() off_built = true return recorder end }
    env.modules['game/memory'] = { new = function() return { available = function() return false end } end }
    said = {}
    local off_ok, off_system = pcall(entry)
    env.check(off_ok and type(off_system) == 'table', '读取面不可用时入口仍能装配')
    env.equal(off_built, false, '实例报告不可用时入口不构造读取面')
    env.check(saw('INPUT source=missing'), '读取面不可用时入口落降级回显')
    env.modules['game/access'] = kept_access
    env.modules['game/memory'] = kept_memory_off

    -- 静音窗自证：窗口内采样器从未为真、且至少一次明确假 ⇒ 关窗计一个静音窗；到阈值只落一行
    local reload_lib = env.modules['game/reload']
    local kept_formb_src = env.modules['game/source_formb']
    local mute_snap, mute_level = nil, false
    env.modules['game/reload'] = setmetatable({
        snapshot = function(self, frame) return mute_snap end,
    }, { __index = reload_lib })
    env.modules['game/source_formb'] = {
        digest = function() return 'stub0000' end,
        new = function()
            return { name = 'form_b', level = function() return mute_level end,
                     describe = function() return {} end, reset = function() end }
        end,
    }
    env.modules['game/memory'] = memory_lib
    said = {}
    local mute_ok, mute_system = pcall(entry)
    env.check(mute_ok and type(mute_system) == 'table', '静音窗现场入口仍能装配')
    if type(mute_system) == 'table' then
        mute_system.activate()
        local function drive(running)
            mute_snap = { reloading = running, mag_reserve = 5, reload_stage = running and 3 or 0,
                ability_running = true, weapon_entity = 7, seat = 0, time = running and 1.0 or 2.5 }
            mute_system.frame(0.016)
        end
        -- 一个整窗＝两帧开窗＋一帧关窗；pressed=true 的窗内出现过真电平（seen=2）⇒ 不计静音。
        local function drive_window(pressed)
            mute_level = pressed == true
            drive(true); drive(true)
            mute_level = false
            drive(false)
        end
        local function mute_hits()
            local hits = 0
            for i = 1, #said do
                if string.find(said[i], 'INPUT-B-MUTE windows=', 1, true) then hits = hits + 1 end
            end
            return hits
        end
        drive_window(false); drive_window(false); drive_window(false)
        env.equal(mute_system.observed.mute, 3, '三个整窗无真电平即计三个静音窗')
        env.equal(mute_hits(), 1, '静音窗到阈值落一行')
        drive_window(true)
        env.equal(mute_system.observed.mute, 3, '有真电平的窗不计静音（计数停在阈值）')
        env.equal(mute_hits(), 1, '计数停在阈值时不再重发（mute_reported 一次性标志）')
        env.equal(mute_system.observed.mute_reported, true, '一次性标志已置位')
    end
    env.modules['game/reload'] = reload_lib
    env.modules['game/source_formb'] = kept_formb_src
    env.modules['game/memory'] = kept_memory

    rawset(_G, 'modules', previous_modules)
    rawset(_G, 'CowboyBingusModLoader', previous_loader)
    _G.print = real_print
    env.equal(rawget(_G, 'modules'), previous_modules, '用例结束后恢复全局模块表')
end
