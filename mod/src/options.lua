-- 可调项：把设置描述变成声明列表，并把外部取值收敛成可用数字。
-- 外部取值一律经过类型与范围检查，不合格就回落默认值，调用方不需要再判断。

local options = {}

-- 声明列表：按 id 升序，便于界面稳定排列
function options.describe(spec)
    local ids = {}
    for id in pairs(spec) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local list = {}
    for index = 1, #ids do
        local id = ids[index]
        local item = spec[id]
        list[#list + 1] = {
            id = id,
            default = item.default,
            min = item.min,
            max = item.max,
        }
    end
    return list
end

-- 单个取值收敛：带取值表的项只认表内取值，其余按数字区间收敛
function options.pick(item, value)
    if type(item.choices) == 'table' then
        if type(value) ~= 'string' then
            return item.default
        end
        for index = 1, #item.choices do
            if item.choices[index] == value then
                return value
            end
        end
        return item.default
    end
    if type(value) ~= 'number' then
        return item.default
    end
    if value ~= value then
        return item.default
    end
    if value < item.min or value > item.max then
        return item.default
    end
    return value
end

-- 全部取值收敛：external 可以为 nil，此时全部使用默认值
function options.resolve(spec, external)
    local values = {}
    for id, item in pairs(spec) do
        values[id] = options.pick(item, external and external[id])
    end
    return values
end

-- 游戏内选项菜单（ModOptionsMenu，api 1）接入：把条参数与语言登记成菜单项，
-- 应用值经同一收敛函数写回设置表；菜单缺席或注册被拒时保持默认值，只落一行具名原因。
options.MENU_NAME = 'Active Reload'

-- 菜单文案两份：默认跟随游戏语言（读宿主翻译注册表的公开字段），也可用语言项手动锁定。
local TEXT = {
    en = {
        width = 'Bar length (%)', width_note = 'Completion bar length as a percentage of screen width.',
        thickness = 'Bar thickness (%)', thickness_note = 'Completion bar thickness as a percentage of screen height.',
        offset = 'Bar offset (%)', offset_note = 'Distance below the crosshair as a percentage of screen width.',
        language = 'Language', language_note = 'Text language of this mod menu.',
        auto = 'Follow game', english = 'English', chinese = 'Chinese',
    },
    zh = {
        width = '进度条长度（%）', width_note = '进度条长度占屏幕宽度的百分比。',
        thickness = '进度条厚度（%）', thickness_note = '进度条厚度占屏幕高度的百分比。',
        offset = '准星下方偏移（%）', offset_note = '进度条在准星下方的竖直偏移，占屏幕宽度的百分比。',
        language = '语言', language_note = '本模组菜单文字语言。',
        auto = '跟随游戏', english = '英文', chinese = '中文',
    },
}

options.MENU_ITEMS = {
    { key = 'bar_width', type = 'slider', id = 'active_reload.bar_length', step = 1,
      label_key = 'width', desc_key = 'width_note' },
    { key = 'bar_thickness', type = 'slider', id = 'active_reload.bar_thickness', step = 0.1,
      label_key = 'thickness', desc_key = 'thickness_note' },
    { key = 'bar_offset', type = 'slider', id = 'active_reload.bar_offset', step = 1,
      label_key = 'offset', desc_key = 'offset_note' },
    { key = 'language', type = 'choice', id = 'active_reload.language',
      choices = { 'auto', 'en', 'zh' }, names = { 'auto', 'english', 'chinese' },
      label_key = 'language', desc_key = 'language_note' },
}
local HUNDRED = 0x64

-- 语言取值：'auto' 跟随游戏语言（注册表 override → 游戏内语言 → Steam 语言），'en'／'zh' 为手动锁定。
local function code_of(env)
    local registry = rawget(env, 'BingusTranslations')
    if type(registry) ~= 'table' then return nil end
    local value = registry.override
    if type(value) ~= 'string' then value = registry.game_language end
    if type(value) ~= 'string' then value = registry.steam_language end
    if type(value) ~= 'string' then return nil end
    return value
end

local function language_of(settings, env)
    local picked = settings.language
    if picked == 'en' or picked == 'zh' then return picked end
    local code = code_of(env)
    if type(code) == 'string' then
        if string.sub(code, 1, 2) == 'zh' then return 'zh' end
        if code == 'schinese' or code == 'tchinese' then return 'zh' end
    end
    return 'en'
end

local function words_of(settings, env)
    if language_of(settings, env) == 'zh' then return TEXT.zh end
    return TEXT.en
end

-- 文案延迟求值：菜单每次打开都会重新取，切换语言后不需要重装
local function text_of(settings, env, key)
    return function()
        return words_of(settings, env)[key]
    end
end

local function write_setting(settings, spec, item, value)
    if item.type == 'choice' then
        local picked = nil
        if type(value) == 'number' and value % 1 == 0 and value >= 1 and value <= #item.choices then
            picked = item.choices[value]
        end
        settings[item.key] = options.pick(spec[item.key], picked)
        return
    end
    local ratio = nil
    if type(value) == 'number' then
        ratio = value / HUNDRED
    end
    settings[item.key] = options.pick(spec[item.key], ratio)
end

-- 菜单项描述：滑块走百分数刻度，选择项把菜单序号映射回取值表
local function descriptor_of(settings, env, item, item_spec)
    local descriptor = { type = item.type, label = text_of(settings, env, item.label_key),
                         mod = options.MENU_NAME, description = text_of(settings, env, item.desc_key) }
    if item.type == 'choice' then
        descriptor.choices, descriptor.default = {}, 1
        for index = 1, #item.choices do
            descriptor.choices[index] = text_of(settings, env, item.names[index])
            if item.choices[index] == settings[item.key] then descriptor.default = index end
        end
        return descriptor
    end
    descriptor.min = item_spec.min * HUNDRED
    descriptor.max = item_spec.max * HUNDRED
    descriptor.step = item.step
    descriptor.default = item_spec.default * HUNDRED
    return descriptor
end

function options.bind(spec, settings, deps)
    local given = deps
    if type(given) ~= 'table' then
        given = {}
    end
    local env = given.env
    if type(env) ~= 'table' then
        env = _G
    end
    local note = given.note
    if type(note) ~= 'function' then
        note = nil
    end
    local menu = rawget(env, 'ModOptionsMenu')
    if type(menu) ~= 'table' or menu.api ~= 1 then
        if note ~= nil then
            note('MENU status=unavailable reason=no-menu')
        end
        return false, 'no-menu'
    end
    local bound = 0
    for index = 1, #options.MENU_ITEMS do
        local item = options.MENU_ITEMS[index]
        local item_spec = spec[item.key]
        if type(item_spec) == 'table' then
            local called, registered, why = pcall(menu.register_option, item.id,
                                                   descriptor_of(settings, env, item, item_spec))
            if called ~= true then
                registered, why = false, registered
            end
            if registered == true then
                write_setting(settings, spec, item, menu.get(item.id))
                menu.on_change(item.id, function(value) write_setting(settings, spec, item, value) end)
                bound = bound + 1
            elseif note ~= nil then
                note('MENU item=' .. item.id .. ' status=refused reason=' .. tostring(why))
            end
        end
    end
    if note ~= nil then
        note('MENU status=bound items=' .. tostring(bound))
    end
    return bound > 0, bound
end

return options
