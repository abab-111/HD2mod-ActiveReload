-- 可调项：声明列表顺序、外部取值收敛、越界与类型回落

return function(env)
    local options = env.modules['options']
    local spec = {
        penalty_percent = { default = 0.2, min = 0.0, max = 1.0 },
        bar_width = { default = 0.2, min = 0.0, max = 0.4 },
    }

    local list = options.describe(spec)
    env.equal(#list, 2, '声明列表条目数与描述一致')
    env.equal(list[1].id, 'bar_width', '声明列表按 id 升序排列')
    env.equal(list[2].id, 'penalty_percent', '声明列表按 id 升序排列')
    env.equal(list[1].min, 0.0, '声明列表带上下界')
    env.equal(list[2].max, 1.0, '声明列表带上下界')

    local values = options.resolve(spec, nil)
    env.near(values.bar_width, 0.2, 1e-12, '没有外部取值时使用默认值')
    env.near(values.penalty_percent, 0.2, 1e-12, '没有外部取值时使用默认值')

    values = options.resolve(spec, { bar_width = 0.3 })
    env.near(values.bar_width, 0.3, 1e-12, '范围内的外部取值生效')
    env.near(values.penalty_percent, 0.2, 1e-12, '缺失的外部取值回落默认值')

    values = options.resolve(spec, {})
    env.near(values.bar_width, 0.2, 1e-12, '空表按默认值处理')

    env.near(options.pick(spec.penalty_percent, 1.0), 1.0, 1e-12, '恰好等于上界时生效')
    env.near(options.pick(spec.penalty_percent, 0.0), 0.0, 1e-12, '恰好等于下界时生效')
    env.near(options.pick(spec.penalty_percent, 1.001), 0.2, 1e-12, '越过上界回落默认值')
    env.near(options.pick(spec.penalty_percent, -0.001), 0.2, 1e-12, '越过下界回落默认值')
    env.near(options.pick(spec.penalty_percent, 0 / 0), 0.2, 1e-12, '非数回落默认值')
    env.near(options.pick(spec.penalty_percent, '0.6'), 0.2, 1e-12, '字符串回落默认值')
    env.near(options.pick(spec.penalty_percent, nil), 0.2, 1e-12, '空值回落默认值')
    env.near(options.pick(spec.penalty_percent, true), 0.2, 1e-12, '布尔值回落默认值')

    -- 改设置 ⇒ 下一帧生效：装配期只 resolve 一次，运行期重取时必须直读活表（无需额外 refresh 机制）
    local live = { penalty_percent = 0.2, bar_width = 0.2 }
    local first = options.resolve(spec, live)
    env.near(first.bar_width, 0.2, 1e-12, '首次收敛取到当时取值')
    live.bar_width = 0.35
    local second = options.resolve(spec, live)
    env.near(second.bar_width, 0.35, 1e-12, '改设置后重取立即生效')
    env.near(first.bar_width, 0.2, 1e-12, '已收敛的旧表不被追溯改动')
    live.bar_width = 0.9
    env.near(options.resolve(spec, live).bar_width, 0.2, 1e-12, '改到越界值时回落默认值')
    env.near(options.pick(spec.bar_width, live.bar_width), 0.2, 1e-12, '单值收敛对越界改动同样生效')

    -- 游戏内菜单接入：三条滑块与语言项登记、菜单已存值写回、回调写回、越界与非数回落默认值
    local spec_bar = {
        bar_width = { default = 0.25, min = 0.10, max = 0.50 },
        bar_thickness = { default = 0.010, min = 0.005, max = 0.020 },
        bar_offset = { default = 0.10, min = 0.05, max = 0.20 },
        language = { default = 'auto', choices = { 'auto', 'en', 'zh' } },
    }
    local settings = options.resolve(spec_bar, nil)
    local registered = {}
    local callbacks = {}
    local lines = {}
    local menu = {
        api = 1,
        register_option = function(id, item)
            registered[#registered + 1] = { id = id, item = item }
            return true
        end,
        get = function(id)
            if id == 'active_reload.bar_length' then
                return 40
            end
            return nil
        end,
        on_change = function(id, callback)
            callbacks[id] = callback
        end,
    }
    local bound, count = options.bind(spec_bar, settings,
        { env = { ModOptionsMenu = menu }, note = function(line) lines[#lines + 1] = line end })
    env.equal(bound, true, '菜单在场时绑定成功')
    env.equal(count, 4, '三条条参数与语言项全部登记')
    env.equal(#registered, 4, '登记调用次数与菜单项一致')
    env.equal(registered[1].id, 'active_reload.bar_length', '登记 id 与条长对应')
    env.equal(registered[1].item.type, 'slider', '登记类型为滑块')
    env.equal(registered[1].item.mod, 'Active Reload', '登记所属模组名')
    env.near(registered[1].item.min, 10, 1e-9, '条长下界为百分之十')
    env.near(registered[1].item.max, 50, 1e-9, '条长上界为百分之五十')
    env.near(registered[1].item.default, 25, 1e-9, '条长默认为百分之二十五')
    env.near(registered[2].item.step, 0.1, 1e-9, '条厚步进为百分之零点一')
    env.equal(registered[4].id, 'active_reload.language', '登记 id 与语言项对应')
    env.equal(registered[4].item.type, 'choice', '语言项登记为选择项')
    env.equal(#registered[4].item.choices, 3, '语言项给出三档取值')
    env.equal(registered[4].item.default, 1, '语言项默认档为跟随游戏')
    env.check(type(registered[1].item.label) == 'function' and type(registered[1].item.description) == 'function',
              '登记带延迟求值的标签与说明（菜单每次打开重取，语言可跟随）')
    env.equal(registered[1].item.label(), 'Bar length (%)', '默认（英文）标签文本')
    env.equal(registered[1].item.description(), 'Completion bar length as a percentage of screen width.',
              '默认（英文）说明文本')
    env.equal(lines[#lines], 'MENU status=bound items=4', '绑定结果落一行')
    env.near(settings.bar_width, 0.40, 1e-12, '菜单已存值写回设置表')
    env.near(settings.bar_thickness, 0.010, 1e-12, '菜单无值时保持默认值')
    env.near(settings.bar_offset, 0.10, 1e-12, '菜单无值时保持默认值')
    env.equal(settings.language, 'auto', '语言项无值时保持默认档')
    callbacks['active_reload.bar_length'](30)
    env.near(settings.bar_width, 0.30, 1e-12, '菜单回调写回设置表')
    callbacks['active_reload.bar_length'](90)
    env.near(settings.bar_width, 0.25, 1e-12, '菜单越界值回落默认值')
    callbacks['active_reload.bar_length']('wide')
    env.near(settings.bar_width, 0.25, 1e-12, '菜单非数回落默认值')

    -- 语言：默认跟随游戏语言（宿主注册表），手动锁定优先，取值表外回落默认
    local lang_spec = { language = { default = 'auto', choices = { 'auto', 'en', 'zh' } } }
    local lang_settings = options.resolve(lang_spec, nil)
    env.equal(lang_settings.language, 'auto', '语言项默认跟随游戏')
    env.equal(options.pick(lang_spec.language, 'zh'), 'zh', '取值表内取值照用')
    env.equal(options.pick(lang_spec.language, 'de'), 'auto', '取值表外取值回落默认')
    env.equal(options.pick(lang_spec.language, 2), 'auto', '非字符串取值回落默认')
    local lang_registered = {}
    local lang_menu = {
        api = 1,
        register_option = function(id, item) lang_registered[#lang_registered + 1] = item return true end,
        get = function() return nil end,
        on_change = function() end,
    }
    local chinese = options.resolve(lang_spec, nil)
    options.bind(lang_spec, chinese, { env = { ModOptionsMenu = lang_menu, BingusTranslations = { game_language = 'schinese' } } })
    env.equal(lang_registered[1].label(), '语言', '游戏语言为中文时标签取中文')
    env.equal(lang_registered[1].description(), '本模组菜单文字语言。', '说明文本同样跟随语言')
    env.equal(lang_registered[1].choices[3](), '中文', '选项文案跟随语言')
    env.equal(lang_registered[1].choices[1](), '跟随游戏', '跟随游戏档文案跟随语言')
    chinese.language = 'en'
    env.equal(lang_registered[1].label(), 'Language', '手动锁定英文后标签取英文')
    env.equal(lang_registered[1].choices[2](), 'English', '手动锁定后选项文案取英文')
    chinese.language = 'auto'
    env.equal(lang_registered[1].label(), '语言', '手动档回到跟随游戏后仍按游戏语言')
    local locked = options.resolve(lang_spec, nil)
    options.bind(lang_spec, locked, { env = { ModOptionsMenu = lang_menu, BingusTranslations = { override = 'en', game_language = 'schinese' } } })
    env.equal(lang_registered[2].label(), 'Language', '注册表强制语言优先于游戏语言')
    local fallback = options.resolve(lang_spec, nil)
    options.bind(lang_spec, fallback, { env = { ModOptionsMenu = lang_menu, BingusTranslations = {} } })
    env.equal(lang_registered[3].label(), 'Language', '语言读不到时回落英文')
    local steam = options.resolve(lang_spec, nil)
    options.bind(lang_spec, steam, { env = { ModOptionsMenu = lang_menu, BingusTranslations = { steam_language = 'schinese' } } })
    env.equal(lang_registered[4].label(), '语言', '游戏语言缺席时按 Steam 语言')

    local choice_settings = options.resolve(lang_spec, nil)
    local choice_menu = {
        api = 1,
        register_option = function() return true end,
        get = function() return 3 end,
    }
    choice_menu.on_change = function(id, callback) choice_menu.callback = callback end
    options.bind(lang_spec, choice_settings, { env = { ModOptionsMenu = choice_menu } })
    env.equal(choice_settings.language, 'zh', '菜单已存序号写回取值表（第三档为中文）')
    choice_menu.callback(2)
    env.equal(choice_settings.language, 'en', '菜单回调序号写回取值表')
    choice_menu.callback(9)
    env.equal(choice_settings.language, 'auto', '菜单越界序号回落默认档')
    choice_menu.callback('zh')
    env.equal(choice_settings.language, 'auto', '菜单非数序号回落默认档')
    print(string.format('LANG game-zh=%s manual-en=%s steam-zh=%s fallback=%s choice-final=%s',
                        lang_registered[1].label(), lang_registered[2].label(),
                        lang_registered[4].label(), lang_registered[3].label(),
                        choice_settings.language))

    local none, why = options.bind(spec_bar, settings, { env = {} })
    env.equal(none, false, '菜单缺席时绑定失败')
    env.equal(why, 'no-menu', '菜单缺席原因具名')
    local wrong = options.bind(spec_bar, settings, { env = { ModOptionsMenu = { api = 2 } } })
    env.equal(wrong, false, '菜单接口版本不符时不绑定')

    local refused = options.resolve(spec_bar, nil)
    local refusal = {
        api = 1,
        register_option = function() return false, 'nope' end,
        get = function() return nil end,
        on_change = function() end,
    }
    local ok_refused, n_refused = options.bind(spec_bar, refused, { env = { ModOptionsMenu = refusal } })
    env.equal(ok_refused, false, '注册被拒时不绑定')
    env.equal(n_refused, 0, '注册被拒时计数为零')
    env.near(refused.bar_width, 0.25, 1e-12, '注册被拒时设置表保持默认值')
end
