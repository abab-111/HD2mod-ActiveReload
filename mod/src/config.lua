-- 全部默认值集中在这里；其它文件只引用键名，不内联数字常量。
-- 资源名、版本与 GUID 属于打包事实，由构建脚本注入的 build 模块提供，不在这里重复。

local config = {}

-- 可调项：键名即设置 id，界面与本地设置共用同一份描述；
-- bar_width 是轨道长度（条长占屏幕宽度的比例），bar_thickness 是条厚（占屏幕高度的比例），
-- bar_offset 是准星下方的竖直偏移（占屏幕宽度的比例），penalty_percent 是按错后的加时比例。
-- 写路径总闸（是否允许 mod 替游戏提交补弹）刻意不进本表：describe 会把它当可调项列给界面，
-- 而该开关不暴露给玩家；正典位置是 config.instant.enabled，开启前须先做实机验证（叠加行为未测）。
config.options = {
    bar_offset = { default = 0.10, min = 0.05, max = 0.20 },
    bar_thickness = { default = 0.010, min = 0.005, max = 0.020 },
    bar_width = { default = 0.25, min = 0.10, max = 0.50 },
    language = { default = 'auto', choices = { 'auto', 'en', 'zh' } },
    penalty_percent = { default = 0.20, min = 0.0, max = 1.0 },
}

-- 条几何：除 align/anchor/layer 外均为屏幕尺寸的比例值；条厚与竖直偏移是可调项，不在这里重复。
config.bar = {
    border = 0.003,   -- 外框线宽（屏高比例）
    align = 0.5,      -- 水平对齐：0.5 即水平居中
    anchor = 0.5,     -- 竖直锚点：准星所在的屏高比例，条挂其正下方
    layer = 1016,     -- 屏幕 GUI 图层：0 到 1023 内排序有效，再往上会翻到界面盒子下方
    marker = 0.008,   -- 游标宽度（屏高比例）：实心加粗，保证在暗色轨道上看得见
    -- 显示层延续阈值（秒）：同一次换弹的动画段之间会闪断，短暂关窗仍算同一条。
    -- 取值依据：实测段间间隔最长 2.867 秒，相邻两次换弹最短间隔 3.578 秒，阈值取两者之间。
    hold_seconds = 3.2,
}

-- 区间：宽度与起点范围均为条长的比例值
config.zone = {
    width = 0.20,
    start_min = 0.20,
    start_max = 0.50,
}

-- 循环：扫过起点为条长比例；fallback_seconds 为读不到游戏侧时长时使用的兜底时长；
-- release_before_new 要求上一轮先松开按键，避免按住不放连续触发。
config.cycle = {
    sweep_start = 0.0,
    fallback_seconds = 2.4,
    release_before_new = true,
}

-- 时钟：按帧增量累加（暂停或菜单不产帧，读数自动冻结）；单帧超过 max_step 秒视为卡顿，
-- 只计数不推进，避免一次长停顿把计时基准冲掉。
config.clock = {
    max_step = 1.0,
}

-- 帧驱动：心跳每 heartbeat_frames 帧落一行存活读数，只为排查「驱动是否在跑」，不进任何判据。
config.driver = {
    heartbeat_frames = 900,
}

-- 配色：红、绿、蓝分量，取值 0 到 1
config.color = {
    frame = { 1.0, 1.0, 1.0 },      -- 外框白
    track = { 0.16, 0.16, 0.16 },   -- 轨道灰
    zone = { 1.0, 1.0, 1.0 },       -- 命中区白
    marker = { 0.95, 0.80, 0.35 },  -- 游标黄色：与灰轨道、白命中区、按错灰红三层均可辨
    miss = { 0.38, 0.14, 0.14 },    -- 按错后的轨道灰红（规格未指定细项，取默认值）
}

config.log = {
    level = 'info',
    prefix = '[Active Reload] ',
    -- 日志文件端点的文件名：只有装配了日志端点件的构建才消费本键，其它构建只读等级与前缀。
    -- 置 nil 即完全不尝试落盘（出口与控制台一致）；名称须匹配 [%w_-]+.log，不含目录分隔符。
    name = 'ActiveReload.log',
}

-- 输入取源：形态 B 为默认实现；sources 里非 true 的候选视为未实现，不可用则退回维持原生读取并落具名原因。
config.inputs = {
    source = 'form_b',
    sources = { form_b = true, bindings = false, key = false },
}

-- 形态 B 规格：地址 = read64(game_base + chain.avatar_manager) + base_rva + 席位*avatar_stride +
-- block_off + 条目*entry_size（先解引用 avatar_manager 全局指针，与研究侧 arc 契约同式）。
-- 条目号直接取 entry 常量（块内物理索引），席位只参与 base 层；'flat' 口径不采用、不实现。
-- 十进制是正典值，行末十六进制是同一数字的另一种写法，门按两栏各自独立复算。
config.inputs.form_b = {
    base_rva = 336,          -- 0x150
    avatar_stride = 686828,  -- 0xA7AEC（曾误抄为 687340 ＝ 0xA7CEC，差 512）
    block_off = 7016,        -- 0x1B68
    entry_size = 32,         -- 0x20，一次读足
    entry = 10,              -- 0xA：行为判定所得条目号（块内物理索引；ARC c2/c3/c4 三场互证）
    index_map = 'direct',    -- 语义一次写清：条目号不按席位折出，'direct' 即「取 entry 常量」
    held_at = 8,             -- 0x8
    held_kind = 'f32',
    mute_windows = 3,        -- 恒 false 达这么多个窗口即自证失败
    hold_epsilon = 0.0,      -- 未测：暂按「严格非零即按下」
    entry_scale = 97,        -- 0x61（'flat' 未采用，保留作规格回声与指纹键）
}

-- 指纹键序：Lua 表遍历序不稳定，拼串、复算与回显都按这个顺序，键序变了指纹就变。
config.inputs.form_b_fingerprint_keys = { 'base_rva', 'avatar_stride', 'block_off', 'entry_size', 'entry',
    'index_map', 'held_at', 'held_kind', 'mute_windows', 'hold_epsilon', 'entry_scale' }

-- 规格指纹（装配回显 spec= 那一段）：按上面的键序拼 键=值;（值走 Lua tostring）后取 sha256 前 8 位小写十六进制。
-- 拼串原文 = base_rva=336;avatar_stride=686828;block_off=7016;entry_size=32;entry=10;index_map=direct;held_at=8;held_kind=f32;mute_windows=3;hold_epsilon=0;entry_scale=97;
-- 规格里任何一项变了这个值就变 ⇒ 改规格必须重算，并同步 test_entry 里的字面断言。
config.inputs.form_b_fingerprint = '8c041a6e'

-- 写路径：默认关闭；开启后仍要求落在换弹窗口内，容量取自本帧快照，读不到就用 capacity_default（0 即不提交）。
config.instant = {
    enabled = false,
    require_window = true,
    capacity_default = nil, -- 【未测】容量表由「首装自收集」形成；缺席即 refused no-capacity，不拿 0 冒充
    capacity_source = 'snapshot',
    log_prefix = '[Active Reload] ',
}

-- 运行期读取面常量：地址一律相对 game.dll（构建 25480438）。
-- 这些值来自运行期实测（探针会话）：组件全局、
-- 管理器内偏移、数组行与实例池布局、玩家链、状态位。任何一项在游戏更新后都可能位移，
-- 位移后必须重新实测，不得就地推测。
config.native = {
    -- 管理器 map 头：base+0 为行数组指针，其后三个计数按下列偏移读
    map = { capacity = 8, empty = 12, mult = 16 },

    chain = {
        player_manager = 53634152,
        local_unit = 936,
        entity_owner = 54968216,
        owner_map = 15871688,
        owner_entities = 15937304,
        entity_stride = 24,
        entity_id = 8,
        unit_id = 12,
        avatar_manager = 53636384,
        avatar_map = 248,
        avatar_count = 108,
        avatar_controller = 5495040,
        controller_stride = 4664,
        identity = 2948,
    },

    -- Avatar 状态行：席位表 at + stride*seat；状态位都在同一字节里
    state = {
        at = 5535792,
        stride = 120,
        bits_at = 23,
        values = {
            first_person = { 14, 'bit', 0 },
            aiming = { 18, 'bit', 2 },
            stamina = { 36, 'f32' },
            reloading = { 23, 'bit', 1 },
            aiming_copy = { 23, 'bit', 5 },
        },
    },

    -- 组件规格：global 为组件全局（相对 game.dll）；map/backref 定位席位；
    -- arrays 按席位索引取行，instance 用实体号再查一次自己的 map 取实例行。
    -- values 的键就是最终扁平字段名，必须带组件前缀（reload 的 REQUIRED 按这些名字取）
    components = {
        {
            component = 'WeaponMagazineComponent', key = 'mag',
            global = 53634632, map = 32, backref = 56,
            arrays = {
                { at = 80, stride = 12, values = { mag_reserve = { 0, 'u32' }, mag_ammo = { 4, 'u32' } } },
                { at = 72, stride = 16, values = { mag_chamber_round = { 8, 'u32' } } },
            },
            instance = { map = 96, at = 160, stride = 160,
                         values = { mag_ammo_max = { 136, 'u32' }, mag_spare_capacity = { 148, 'u32' },
                                    mag_chambered = { 156, 'u8' } } },
        },
        {
            component = 'WeaponRoundsComponent', key = 'rounds',
            global = 53636336, map = 40, backref = 64,
            arrays = {
                { at = 88, stride = 20,
                  values = { rounds_reserve = { 0, 'u32' }, rounds_raw_selected = { 4, 'u32' },
                             rounds_0 = { 8, 'u32' }, rounds_1 = { 12, 'u32' } } },
                { at = 80, stride = 24, values = { rounds_chamber_round = { 16, 'u32' } } },
            },
            instance = { map = 104, at = 168, stride = 136,
                         values = { capacity_0 = { 72, 'f32' }, capacity_1 = { 76, 'f32' },
                                    rounds_spare_capacity = { 80, 'u32' }, rounds_chambered = { 104, 'u8' } } },
        },
        {
            component = 'WeaponReloadComponent', key = 'reload',
            global = 53635696, map = 32, backref = 56,
            arrays = { { at = 80, stride = 4, values = { reload_stage = { 0, 'u32' } } } },
            instance = { map = 96, at = 160, stride = 80,
                         values = { reload_ability = { 4, 'u32' } } },
        },
        {
            component = 'AbilityComponent', key = 'ability',
            global = 53634624, map = 24, backref = 48,
            arrays = { { at = 56, stride = 224,
                         values = { ability_id = { 0, 'u32' }, ability_time = { 8, 'f32' },
                                    ability_running = { 16, 'u8' }, action_events = { 24, 'u32' } } } },
        },
        {
            component = 'WieldableComponent', key = 'wieldable',
            global = 53634864, map = 24, backref = 48,
            arrays = { { at = 56, stride = 4, values = { raw_wielded_by = { 0, 'u32' } } } },
        },
        {
            component = 'WeaponWielderComponent', key = 'wielder',
            global = 53634080, map = 48, backref = 72,
            arrays = { { at = 96, stride = 464,
                         values = { wield_0 = { 0, 'u32' }, wield_1 = { 80, 'u32' } } } },
        },
    },
}

return config
