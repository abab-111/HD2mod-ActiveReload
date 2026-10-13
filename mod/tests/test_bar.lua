-- 条：几何、可见性、配色与绘制端（屏幕 GUI retained 面）的行为面用例。
-- 绘制端用桩引擎，只记录调用与句柄，验证「先建后更、同序号复用、未用槽位收起」。

return function(env)
    local bar = env.modules['ui/bar']
    local config_lib = env.modules['config']
    local options_lib = env.modules['options']
    env.check(type(bar) == 'table', '条模块在用例环境里可加载')
    if type(bar) ~= 'table' then
        return
    end

    -- 一、几何：屏宽 1920、屏高 1080；条长 25% 屏宽、厚 1% 屏高、竖直偏移 10% 屏宽、边框 0.003 屏高、游标宽 0.8% 屏高
    local screen = { width = 1920, height = 1080 }
    local view = { width = 0.25, thickness = 0.010, offset = 0.10 }
    local box = { border = 0.003, align = 0.5, anchor = 0.5, marker = 0.008 }
    local layout = bar.layout(screen, box, view, 0.5, 0.20, 0.40)
    env.near(layout.outer.width, 480, 1e-9, '条长按屏宽比例')
    env.near(layout.outer.height, 10.8, 1e-9, '条厚按屏高比例')
    env.near(layout.outer.x, 720, 1e-9, '水平居中')
    env.near(layout.outer.y, 348, 1e-9, '竖直偏移按屏宽比例，挂在准星正下方（屏高中心向下）')
    env.near(layout.inner.x, 723.24, 1e-9, '内框让开边框线宽')
    env.near(layout.inner.height, 4.32, 1e-9, '内框上下各让开一线')
    env.near(layout.zone.x, 816, 1e-9, '命中区起点按条长比例')
    env.near(layout.zone.width, 96, 1e-9, '命中区宽度按条长比例')
    env.near(layout.marker.x, 955.68, 1e-9, '游标以扫过位置为中心')
    env.near(layout.marker.width, 8.64, 1e-9, '游标宽度按屏高比例（实心加粗）')
    print(string.format('BAR GEOMETRY outer=(%.0f,%.0f) size=(%.0f,%.1f) inner=(%.2f,%.2f) zone=(%.0f,%.0f) marker=(%.2f,%.2f)',
                        layout.outer.x, layout.outer.y, layout.outer.width, layout.outer.height,
                        layout.inner.x, layout.inner.height, layout.zone.x, layout.zone.width,
                        layout.marker.x, layout.marker.width))

    -- 二、可见性：窗口内且本轮仍在扫过才画
    env.equal(bar.visible({ window = true, phase = 'sweep' }, 'sweep'), true, '窗口内扫过期可见')
    env.equal(bar.visible({ window = true, phase = 'idle' }, 'sweep'), false, '命中即转空闲，框立即消失')
    env.equal(bar.visible({ window = false, phase = 'sweep' }, 'sweep'), false, '窗关即不可见')
    env.equal(bar.visible({}, 'sweep'), false, '没有窗口字段时不可见')

    -- 二·2 显示门：同一次换弹的动画段之间闪断，短暂关窗仍算同一条；写入锁存期一律收起。
    -- 阈值取配置常量；按实测数据带验两侧边界：段间 2.9 秒仍合并，3.6 秒不再合并。
    local hold = config_lib.bar.hold_seconds
    env.near(hold, 3.2, 1e-12, '合一阈值取 3.2 秒（段间最长 2.867 秒与相邻换弹最短 3.578 秒之间）')
    local gate = bar.hold(hold)
    env.equal(bar.gate(gate, true, 10.0, false), true, '窗口开着即显示')
    env.equal(bar.gate(gate, false, 10.1, false), true, '短暂关窗仍在延续期内显示')
    env.equal(bar.gate(gate, false, 13.0, false), true, '关窗后 2.9 秒仍在延续期内（段间闪断合并为同一条）')
    env.equal(bar.gate(gate, false, 13.7, false), false, '关窗后 3.6 秒超过延续期收起')
    env.equal(bar.gate(gate, true, 14.0, false), true, '下一轮窗口重新显示')
    env.equal(bar.gate(gate, true, 14.1, true), false, '写入锁存期硬抑制显示')
    env.equal(bar.gate(gate, false, 14.2, false), false, '硬抑制后不靠延续期复活')
    env.equal(bar.gate(bar.hold(nil), true, 15.0, false), true, '阈值缺省时窗口开着仍显示')
    local merge, split = bar.hold(hold), bar.hold(hold)
    bar.gate(merge, true, 20.0, false)
    bar.gate(split, true, 20.0, false)
    bar.gate(merge, false, 20.1, false)
    bar.gate(split, false, 20.1, false)
    print(string.format('BAR GATE threshold=%.1f merge-2.9s=%s split-3.6s=%s suppress=%s expiry=%s',
                        hold,
                        tostring(bar.gate(merge, false, 23.0, false)),
                        tostring(bar.gate(split, false, 23.7, false)),
                        tostring(bar.gate(bar.hold(hold), true, 30.0, true)),
                        tostring(bar.gate(bar.hold(hold), false, 31.0, false))))
    print(string.format('BAR VISIBLE sweep=%s hit=%s closed=%s blank=%s',
                        tostring(bar.visible({ window = true, phase = 'sweep' }, 'sweep')),
                        tostring(bar.visible({ window = true, phase = 'idle' }, 'sweep')),
                        tostring(bar.visible({ window = false, phase = 'sweep' }, 'sweep')),
                        tostring(bar.visible({}, 'sweep'))))

    -- 三、配色：按错后轨道改灰红，其余分量沿用默认配色
    local color = config_lib.color
    local normal = bar.palette(color, 0)
    env.equal(normal.track, color.track, '未按错时轨道用默认灰')
    local missed = bar.palette(color, 1)
    env.equal(missed.track, color.miss, '按错后轨道改灰红')
    env.equal(missed.zone, color.zone, '按错不改命中区色')
    env.equal(missed.marker, color.marker, '按错不改游标色')
    env.equal(missed.frame, color.frame, '按错不改边框色')
    env.equal(bar.palette(color, nil).track, color.track, '按错计数读不到时按未按错处理')
    env.near(color.marker[1], 0.95, 1e-9, '游标取黄色（第一通道）')
    env.near(color.marker[2], 0.80, 1e-9, '游标取黄色（第二通道）')
    env.near(color.marker[3], 0.35, 1e-9, '游标取黄色（第三通道）')
    env.check(color.marker[3] < color.zone[3] - 0.5,
              '游标与白命中区不同色（游标扫过命中带时仍可辨）')
    print(string.format('BAR PALETTE normal=(%.2f,%.2f,%.2f) miss=(%.2f,%.2f,%.2f) marker=(%.2f,%.2f,%.2f) zone-kept=%s',
                        normal.track[1], normal.track[2], normal.track[3],
                        missed.track[1], missed.track[2], missed.track[3],
                        color.marker[1], color.marker[2], color.marker[3],
                        tostring(missed.zone == color.zone)))

    -- 四、绘制顺序：桩绘制端记录调用序
    local calls = {}
    local recorder = {
        rect = function(rect, fill) calls[#calls + 1] = { 'rect', rect, fill } end,
        frame = function(rect, thickness, fill) calls[#calls + 1] = { 'frame', rect, thickness, fill } end,
    }
    env.equal(bar.draw(recorder, layout, color, box.border), true, '绘制提交成功')
    env.equal(#calls, 4, '一次绘制四次调用（槽、命中区、游标、外框）')
    env.equal(calls[1][1], 'rect', '先填充槽')
    env.equal(calls[2][1], 'rect', '再填充命中区')
    env.equal(calls[3][1], 'rect', '再填充游标')
    env.equal(calls[4][1], 'frame', '最后描边')
    env.equal(calls[1][2], layout.inner, '槽填在内框上')
    env.equal(calls[4][2], layout.outer, '描边描在外框上')
    env.equal(bar.draw(nil, layout, color, box.border), false, '没有绘制端时回假')
    env.equal(bar.draw({}, layout, color, box.border), true, '绘制端缺方法时跳过而不报错')

    -- 五、绘制端（引擎面）：桩 stingray 记录引擎调用
    local made, updated, created, picked = 0, 0, 0, nil
    local engine = {
        Vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
        Vector2 = function(x, y) return { x = x, y = y } end,
        Color = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end,
        Gui = {
            resolution = function() return 1920, 1080 end,
            rect = function(gui, position, size, fill)
                made = made + 1
                return { handle = made }
            end,
            update_rect = function(gui, id, position, size, fill) updated = updated + 1 end,
        },
        World = {
            create_screen_gui = function(world, mode, one, two)
                created = created + 1
                picked = world
                return { screen = true }
            end,
        },
        Application = {
            main_world = function() return 'main' end,
            worlds = function() return { 'main', 'mission' } end,
        },
    }
    local surface = bar.sink({ env = { stingray = engine }, layer = 7 })
    local measured = bar.screen(surface)
    env.equal(measured.width, 1920, '屏幕尺寸取引擎分辨率（宽）')
    env.equal(measured.height, 1080, '屏幕尺寸取引擎分辨率（高）')
    env.equal(created, 1, '取面只建一次屏幕 GUI')
    env.equal(picked, 'mission', '优先挂到非主世界')
    env.equal(surface.layer, 7, '图层取自构造参数')

    bar.begin(surface)
    bar.rect(surface, { x = 0, y = 0, width = 10, height = 10 }, color.track)
    bar.rect(surface, { x = 0, y = 0, width = 10, height = 10 }, color.track)
    bar.finish(surface)
    env.equal(made, 2, '首次填充按需新建引擎对象')
    env.equal(updated, 0, '同一帧内新建的槽位不再更新')

    bar.begin(surface)
    bar.rect(surface, { x = 0, y = 0, width = 10, height = 10 }, color.track)
    bar.rect(surface, { x = 0, y = 0, width = 10, height = 10 }, color.track)
    bar.rect(surface, { x = 0, y = 0, width = 10, height = 10 }, color.track)
    bar.finish(surface)
    env.equal(made, 3, '只有新槽位才新建引擎对象')
    env.equal(updated, 2, '已有槽位改走更新')

    bar.begin(surface)
    bar.rect(surface, { x = 0, y = 0, width = 10, height = 10 }, color.track)
    bar.finish(surface)
    env.equal(updated, 5, '未用到的槽位在收帧时缩成零尺寸')

    bar.clear(surface)
    env.equal(updated, 8, '清面把全部槽位收起')

    engine.Application.worlds = function() return { 'main' } end
    bar.screen(surface)
    env.equal(created, 2, '目标世界不在存活列表时重建屏幕 GUI')
    env.equal(picked, 'main', '重建时回落到主世界')
    print(string.format('BAR SINK created=%d picked=%s made=%d updated=%d stopped=%s',
                        created, tostring(picked), made, updated, tostring(surface.stopped)))

    -- 绘制一帧：窗口内扫过才提交，命中与窗关都只清面
    local submitted, sized = 0, nil
    local function submit(measured)
        submitted = submitted + 1
        sized = measured
        return 'submitted'
    end
    bar.clear(surface)
    env.equal(bar.render(surface, { window = true, phase = 'sweep' }, 'sweep', submit), 'submitted',
              '窗口内扫过时提交一帧并透传结论')
    env.equal(submitted, 1, '提交回调被调用一次')
    env.equal(sized.width, 1920, '提交回调拿到引擎屏幕尺寸')
    env.equal(bar.render(surface, { window = true, phase = 'idle' }, 'sweep', submit), true, '命中后只清面不提交')
    env.equal(submitted, 1, '命中后不再调用提交回调')
    env.equal(bar.render(surface, { window = false, phase = 'sweep' }, 'sweep', submit), true, '窗关后只清面不提交')
    env.equal(submitted, 1, '窗关后不再调用提交回调')

    -- 六、取面失败：按上限重试后放弃，只落一行具名原因
    local notes = {}
    local dark = bar.sink({ env = {}, layer = 0, note = function(line) notes[#notes + 1] = line end })
    env.equal(bar.screen(dark), nil, '没有绘制面时回 nil')
    for index = 1, 0x78 do
        bar.screen(dark)
    end
    env.equal(#notes, 1, '取面失败只落一行具名原因')
    env.equal(notes[1], 'BAR status=unavailable reason=no-gui-api', '具名原因指出缺的是绘制接口')
    env.equal(dark.stopped, true, '超过重试上限后停止重试')
    local worldless = { Gui = {}, World = {}, Application = { main_world = function() return nil end } }
    env.equal(bar.screen(bar.sink({ env = { stingray = worldless }, layer = 0 })), nil, '没有可用世界时回 nil')
    local broken = { Gui = {}, World = { create_screen_gui = function() return nil end },
                     Application = { main_world = function() return 'main' end } }
    env.equal(bar.screen(bar.sink({ env = { stingray = broken }, layer = 0 })), nil, '屏幕 GUI 建不出来时回 nil')
    print(string.format('BAR RETRY attempts=%d notes=%d line=%s stopped=%s',
                        0x78, #notes, notes[1], tostring(dark.stopped)))

    -- 七、可调项收敛：三条条参数越界一律回落默认值
    local spec = config_lib.options
    env.near(spec.bar_width.default, 0.25, 1e-12, '默认条长为 25% 屏宽')
    env.near(spec.bar_thickness.default, 0.010, 1e-12, '默认条厚为 1% 屏高')
    env.near(spec.bar_offset.default, 0.10, 1e-12, '默认竖直偏移为 10% 屏宽')
    env.near(options_lib.pick(spec.bar_width, 0.99), 0.25, 1e-12, '条长越界回落默认值')
    env.near(options_lib.pick(spec.bar_thickness, 0.5), 0.010, 1e-12, '条厚越界回落默认值')
    env.near(options_lib.pick(spec.bar_offset, 0.5), 0.10, 1e-12, '竖直偏移越界回落默认值')
    env.near(options_lib.pick(spec.bar_width, 0.4), 0.4, 1e-12, '条长在范围内照用')
    local resolved = options_lib.resolve(spec, { bar_offset = 0.05, bar_thickness = 0.02 })
    env.near(resolved.bar_offset, 0.05, 1e-12, '范围内外部取值生效（偏移）')
    env.near(resolved.bar_thickness, 0.02, 1e-12, '范围内外部取值生效（厚）')
    env.near(resolved.bar_width, 0.25, 1e-12, '未给出的项取默认值')
    local listed = options_lib.describe(spec)
    env.equal(#listed, 5, '可调项共五条（三条条参数、语言、加时比例）')
    env.equal(listed[1].id, 'bar_offset', '声明按 id 升序：首条为竖直偏移')
    env.equal(listed[2].id, 'bar_thickness', '声明按 id 升序：第二条为条厚')
    env.equal(listed[3].id, 'bar_width', '声明按 id 升序：第三条为条长')
    env.equal(listed[4].id, 'language', '声明按 id 升序：第四条为语言')
    env.equal(listed[5].id, 'penalty_percent', '声明按 id 升序：末条为加时比例')
    env.equal(spec.language.default, 'auto', '语言项默认跟随游戏语言')
    env.equal(#spec.language.choices, 3, '语言项有跟随游戏、英文、中文三档')
    print(string.format('BAR OPTIONS count=%d ids=%s width=%s thickness=%s offset=%s language=%s',
                        #listed, listed[1].id .. '|' .. listed[2].id .. '|' .. listed[3].id .. '|' ..
                        listed[4].id .. '|' .. listed[5].id,
                        tostring(spec.bar_width.default), tostring(spec.bar_thickness.default),
                        tostring(spec.bar_offset.default), tostring(spec.language.default)))
end
