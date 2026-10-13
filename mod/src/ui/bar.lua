-- 条的几何、绘制顺序与绘制端实现。
-- 几何与顺序是纯计算；绘制端把矩形提交给引擎的屏幕 GUI，同一序号复用同一个引擎对象。
-- 绘制端接口（调用方注入，也可直接用本文件提供的 bar.sink）：
--   sink.rect(rect, color)             填充矩形
--   sink.frame(rect, thickness, color) 描边
-- rect 为 { x, y, width, height }，单位为屏幕像素；color 为 { 红, 绿, 蓝 }。

local bar = {}

-- 取面的重试上限（帧）：超过即放弃并只落一行具名原因，不逐帧重试。
bar.ATTEMPTS = 0x78

-- 收起时用的颜色（隐藏＝缩成零尺寸）
bar.HIDDEN = { 0, 0, 0 }

-- 几何换算：屏幕尺寸 + 条参数 + 本轮视图参数 -> 各矩形，纯计算
function bar.layout(screen, box, view, position, zone_start, zone_finish)
    local height = screen.height * view.thickness
    local width = screen.width * view.width
    local border = screen.height * box.border
    local marker = screen.height * box.marker
    local x = (screen.width - width) * box.align
    local y = screen.height * box.anchor - screen.width * view.offset
    return {
        outer = { x = x, y = y, width = width, height = height },
        inner = {
            x = x + border,
            y = y + border,
            width = width - border * 2,
            height = height - border * 2,
        },
        zone = {
            x = x + width * zone_start,
            y = y,
            width = width * (zone_finish - zone_start),
            height = height,
        },
        marker = {
            x = x + width * position - marker * 0.5,
            y = y,
            width = marker,
            height = height,
        },
    }
end

-- 可见性：窗口内且本轮仍在扫过才画（命中即转空闲 ⇒ 框立即消失；窗关即清面）
function bar.visible(cycle, sweeping)
    if cycle.window ~= true then
        return false
    end
    return cycle.phase == sweeping
end

-- 显示门状态：一次换弹的动画段之间会闪断，短暂关窗仍算同一条（阈值由调用方给，依据实测间隔）
function bar.hold(seconds)
    local hold = 0
    if type(seconds) == 'number' and seconds > 0 then hold = hold + seconds end
    return { held = false, hold = hold, release_at = nil }
end

-- 显示门：真实窗口 -> 显示窗口。硬抑制一律收起；关窗后在延续期内仍显示，超时才收起
function bar.gate(state, open, seconds, suppress)
    if suppress == true then
        state.held, state.release_at = false, nil
        return false
    end
    if open == true then
        state.held, state.release_at = true, nil
        return true
    end
    if state.held ~= true then return false end
    if type(seconds) ~= 'number' then return true end
    if state.release_at == nil then state.release_at = seconds + state.hold end
    if seconds <= state.release_at then return true end
    state.held, state.release_at = false, nil
    return false
end

-- 配色：按错后轨道改灰红，其余分量沿用默认配色
function bar.palette(color, misses)
    if type(misses) == 'number' and misses > 0 then
        return { track = color.miss, zone = color.zone, marker = color.marker, frame = color.frame }
    end
    return color
end

-- 绘制：槽、区间、标记线、外框
function bar.draw(sink, layout, color, border)
    if type(sink) ~= 'table' then
        return false
    end
    if type(sink.rect) == 'function' then
        sink.rect(layout.inner, color.track)
        sink.rect(layout.zone, color.zone)
        sink.rect(layout.marker, color.marker)
    end
    if type(sink.frame) == 'function' then
        sink.frame(layout.outer, border, color.frame)
    end
    return true
end

-- 颜色换算：0 到 1 的分量 -> 引擎要的整数分量（透明度满）
local function shade(api, color)
    return api.Color(0xFF, math.floor(color[1] * 0xFF + 0.5),
                     math.floor(color[2] * 0xFF + 0.5), math.floor(color[3] * 0xFF + 0.5))
end

-- 目标世界：优先非主世界（对局世界），其次主世界；都取不到即无面可挂
local function pick_world(App)
    if type(App) ~= 'table' then
        return nil
    end
    local main = nil
    if type(App.main_world) == 'function' then
        main = App.main_world()
    end
    local list = nil
    if type(App.worlds) == 'function' then
        list = App.worlds()
    end
    if type(list) == 'table' then
        for index = 1, #list do
            if list[index] ~= main then
                return list[index]
            end
        end
    end
    return main
end

-- 世界是否仍在存活列表里（列表取不到时按存活处理，避免误弃已建好的面）
local function world_live(App, world)
    if type(App) ~= 'table' or type(App.worlds) ~= 'function' then
        return true
    end
    local list = App.worlds()
    if type(list) ~= 'table' then
        return true
    end
    for index = 1, #list do
        if list[index] == world then
            return true
        end
    end
    return false
end

-- 绘制端构造：deps.env 供测试注入（缺省宿主全局），deps.layer 为 GUI 图层，deps.note 收一行具名原因
function bar.sink(deps)
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
    local layer = given.layer
    if type(layer) ~= 'number' then
        layer = 0
    end
    -- 绘制端对外是平调用接口（sink.rect(rect, color)／sink.frame(rect, thickness, color)），
    -- 因此这里把内部方法包成闭包挂上，避免调用方需要自带 self。
    local object = { env = env, note = note, layer = layer, api = nil, gui = nil, world = nil,
                     ids = {}, used = 0, tries = 0, stopped = false }
    object.rect = function(rect, color)
        return bar.rect(object, rect, color)
    end
    object.frame = function(rect, thickness, color)
        return bar.frame(object, rect, thickness, color)
    end
    return object
end

-- 取面：把屏幕 GUI 挂到目标世界上；已建且世界仍存活即复用；失败按上限重试后放弃
function bar.attach(self)
    local stingray = self.env.stingray
    if type(stingray) ~= 'table' then
        stingray = nil
    end
    if self.gui ~= nil then
        local app = nil
        if stingray ~= nil then
            app = stingray.Application
        end
        if world_live(app, self.world) then
            return self.api
        end
        self.api, self.gui, self.world, self.ids, self.used = nil, nil, nil, {}, 0
    end
    if self.stopped == true then
        return nil
    end
    local why = nil
    if stingray == nil or type(stingray.Gui) ~= 'table' or type(stingray.World) ~= 'table' then
        why = 'no-gui-api'
    else
        local world = pick_world(stingray.Application)
        if world == nil then
            why = 'no-world'
        else
            local made = stingray.World.create_screen_gui(world, 'scale', 1, 1)
            if made == nil then
                why = 'no-screen-gui'
            else
                self.api, self.gui, self.world, self.ids, self.used = stingray, made, world, {}, 0
                return stingray
            end
        end
    end
    self.tries = self.tries + 1
    if self.tries >= bar.ATTEMPTS then
        self.stopped = true
        if self.note ~= nil then
            self.note('BAR status=unavailable reason=' .. why)
        end
    end
    return nil
end

-- 屏幕尺寸：取引擎分辨率；取不到回 nil（调用方据此跳过本帧）
function bar.screen(self)
    local api = bar.attach(self)
    if api == nil then
        return nil
    end
    local width, height = api.Gui.resolution()
    if type(width) ~= 'number' or type(height) ~= 'number' then
        return nil
    end
    return { width = width, height = height }
end

-- 填充一个矩形：先建后更，同一序号复用同一个引擎对象
function bar.rect(self, rect, color)
    local api = bar.attach(self)
    if api == nil then
        return false
    end
    local index = self.used + 1
    self.used = index
    local position = api.Vector3(rect.x, rect.y, self.layer)
    local size = api.Vector2(rect.width, rect.height)
    local fill = shade(api, color)
    local id = self.ids[index]
    if id == nil then
        id = api.Gui.rect(self.gui, position, size, fill)
        if id == nil then
            return false
        end
        self.ids[index] = id
    else
        api.Gui.update_rect(self.gui, id, position, size, fill)
    end
    return true
end

-- 描边：四条细矩形（上、下、左、右）
function bar.frame(self, rect, thickness, color)
    local ok = bar.rect(self, { x = rect.x, y = rect.y, width = rect.width, height = thickness }, color)
    local under = { x = rect.x, y = rect.y + rect.height - thickness, width = rect.width, height = thickness }
    if bar.rect(self, under, color) ~= true then
        ok = false
    end
    if bar.rect(self, { x = rect.x, y = rect.y, width = thickness, height = rect.height }, color) ~= true then
        ok = false
    end
    local side = { x = rect.x + rect.width - thickness, y = rect.y, width = thickness, height = rect.height }
    if bar.rect(self, side, color) ~= true then
        ok = false
    end
    return ok
end

-- 一帧开始：序号归零，本帧从第一个槽位重填
function bar.begin(self)
    self.used = 0
    return true
end

-- 一帧结束：本帧没用到的槽位缩成零尺寸
function bar.finish(self)
    local api = self.api
    if api == nil then
        return false
    end
    for index = self.used + 1, #self.ids do
        api.Gui.update_rect(self.gui, self.ids[index], api.Vector3(0, 0, self.layer),
                            api.Vector2(0, 0), shade(api, bar.HIDDEN))
    end
    return true
end

-- 清面：整条收起（窗口外与命中后都走这里），下次进窗口再按需重画
function bar.clear(self)
    self.used = 0
    return bar.finish(self)
end

-- 绘制一帧：窗口内且本轮仍在扫过才提交，否则清面；submit(screen) 为提交回调，返回值即本帧结论
function bar.render(self, cycle, sweeping, submit)
    local screen = bar.screen(self)
    if screen == nil then
        return false
    end
    if bar.visible(cycle, sweeping) ~= true then
        return bar.clear(self)
    end
    bar.begin(self)
    local submitted = submit(screen)
    bar.finish(self)
    return submitted
end

return bar
