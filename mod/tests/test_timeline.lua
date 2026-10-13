-- 时长与位置换算：加时比例、进度截断、起点偏移
-- 加时比例覆盖默认值 0.20 与两个端点 0、1.0

return function(env)
    local timeline = env.modules['core/timeline']

    env.near(timeline.duration(2.0, 0, 0.20), 2.0, 1e-12, '未按错时时长等于基础时长')
    env.near(timeline.duration(2.0, 1, 0.20), 2.4, 1e-12, '按错一次时长变为 1.2 倍')
    env.near(timeline.duration(2.0, 3, 0.20), 3.2, 1e-12, '按错三次时长按次数累积')
    env.near(timeline.duration(2.0, 1, 0.0), 2.0, 1e-12, '加时比例为 0 时时长不变')
    env.near(timeline.duration(2.0, 1, 1.0), 4.0, 1e-12, '加时比例为 1.0 时总时长翻倍')
    env.near(timeline.duration(2.0, -1, 0.20), 2.0, 1e-12, '负数按错次数不缩短时长')
    env.near(timeline.duration(2.0, 1, -1), 2.0, 1e-12, '负加时比例不缩短时长')
    env.near(timeline.duration(0, 1, 0.20), 0.0, 1e-12, '零基础时长保持为零')

    env.near(timeline.position(0, 2.0, 0.0), 0.0, 1e-12, '起点处位置为起点')
    env.near(timeline.position(0.5, 2.0, 0.0), 0.25, 1e-12, '四分之一进度处位置')
    env.near(timeline.position(1.0, 2.0, 0.0), 0.5, 1e-12, '半程位置')
    env.near(timeline.position(2.0, 2.0, 0.0), 1.0, 1e-12, '到时长时位置为条长末端')
    env.near(timeline.position(3.0, 2.0, 0.0), 1.0, 1e-12, '超过时长后位置截断在末端')
    env.near(timeline.position(-1.0, 2.0, 0.0), 0.0, 1e-12, '负时间截断在起点')
    env.near(timeline.position(1.0, 0, 0.0), 1.0, 1e-12, '零时长直接落在条长末端')
    env.near(timeline.position(1.0, 2.0, 0.5), 0.75, 1e-12, '带起点偏移的半程位置')
    env.near(timeline.position(1.0, 2.0, 1.0), 1.0, 1e-12, '起点已在末端时不再前进')
    env.near(timeline.position(1.0, 2.0, -0.5), 0.25, 1e-12, '起点为负时按同一公式换算')
end
