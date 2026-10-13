-- 写路径接线：授权包独有的装配件，默认包不含本文件。职责：把 reload.send 的唯一 request 注入点接到 instant；按本帧快照采集容量；落证据行。
-- 闸门＝模块在场自判（授权与默认的唯一差异轴是模块集）：本文件缺席 ⇒ 入口 wiring 恒为 false、闸门维持关闭、reload.send 逐字回 false,'disabled'、证据行一行不落。
-- 本件只转述 instant 的结果（判定、回滚、失败语义全在 instant.lua），不复制其判据、不自己写内存；写能力来自随包 vendored 的 bingus_write，本件不含任何写调用。
-- 依赖注入 wiring.new({ modules, config, logger, access, trigger, observed })；缺依赖不抛异常，回 gate=false。

local wiring = {}

local MAG_KEY, ABILITY_KEY = 'mag', 'ability'
local POINTER_WIDTH = 8
local NONE = 'none'

local function text_or(value)
    if value == nil then return NONE end
    return tostring(value)
end

local function number_or(name, value)
    if type(value) ~= 'number' then return name .. '=' .. NONE end
    return name .. '=' .. string.format('%d', value)
end

local function field_of(values, name)   -- 表内取字段：缺表或缺键一律回 nil（立规 1：不用 and/or 承载 falsy 值/哨兵/多返回值）
    if type(values) ~= 'table' then return nil end
    return values[name]
end

-- 席位行地址＝管理器 + 数组表偏移处取表指针，再按席位索引走步长（与 access.lua 的 row_at 同式）；只走公开面（trigger.rows 席位表 + access.memory）。
local function row_address(self, kind)
    local rows = self.trigger ~= nil and self.trigger.rows or nil
    local seats = rows ~= nil and rows.seats or nil
    local seat = seats ~= nil and seats[kind] or nil
    local spec = seat ~= nil and seat.spec or nil
    local array = spec ~= nil and spec.arrays ~= nil and spec.arrays[1] or nil
    if array == nil then return nil end
    if type(seat.manager) ~= 'number' or type(seat.index) ~= 'number' then return nil end
    local memory = self.access ~= nil and self.access.memory or nil
    if memory == nil then return nil end
    local head = memory:read(seat.manager + array.at, POINTER_WIDTH)
    if head == nil then return nil end
    local base = memory:pointer(head, 0)
    if type(base) ~= 'number' then return nil end
    return base + seat.index * array.stride
end

local function locate(self, kind)   -- instant 的 locate 契约：kind -> address|nil（取不到即缺席，不猜地址）
    return row_address(self, kind)
end

local function read_at(self, address, size)   -- instant 的 read 契约：address, size -> string|nil，只走读取面适配器的公开方法
    local memory = self.access ~= nil and self.access.memory or nil
    if memory == nil then return nil end
    return memory:read(address, size)
end

local function note(self, line)
    if self.log ~= nil then self.log(line) end
end

-- 公共时序字段（判读用）：t＝会话已开秒数、f＝帧号，取自帧驱动时钟（与判定同一时基）；窗内行再带 w＝本窗已开秒数；字段一律追加在既有字段之后。
local function stamp(self, with_window)
    local ticker = self.ticker
    local seconds = type(ticker) == 'table' and ticker.seconds or nil
    local frames = type(ticker) == 'table' and ticker.frames or nil
    local text = ' t=' .. (seconds ~= nil and string.format('%.3f', seconds) or NONE) ..
        ' f=' .. (frames ~= nil and string.format('%d', frames) or NONE)
    if with_window == true and seconds ~= nil and self.window_at ~= nil then
        text = text .. ' w=' .. string.format('%.3f', seconds - self.window_at)
    end
    return text
end

-- 容量首装自收集：只在自然换弹窗关闭的那一帧采一次，值须 >0 才认；采集成功前 capacity_default 缺席 ⇒ instant 一律
-- refused no-capacity（安全降级，绝不写零）；采集后写回配置，写值仍由 instant 从本帧快照算出。
local function capture(self, snap)
    if self.taken == true or snap == nil then return nil end
    local ammo = snap.mag_ammo
    if type(ammo) ~= 'number' or ammo <= 0 then return nil end
    self.taken = true
    self.capacity = ammo
    self.config.instant.capacity_default = ammo
    return ammo
end

local function held_text(name, source, index)   -- 点位读数文本：f32；读不到回 none，不以 0 冒充（同 source_formb 的 H3 纪律）。
    local value = source ~= nil and source.read_held(index) or nil
    return type(value) == 'number' and (name .. '=' .. string.format('%.3f', value)) or (name .. '=' .. NONE)
end

local function readface(self)   -- 读面自检行：链解析成功后落一次（逐帧去重，直到本帧才作废）；只观测，不进任何判据、不改窗口语义。
    local access = self.access
    if access == nil then return nil end   -- 读取面整体缺席（无适配器/无数字基址）⇒ 链不可解析，零行、不以 0 冒充
    local spec = self.config.inputs.form_b
    local seat = access.walked ~= nil and access.walked.seat or nil
    local rva = access.chain ~= nil and access.chain.avatar_manager or nil
    local text = type(rva) == 'number' and type(access.game) == 'number' and access.memory:read(access.game + rva, 8) or nil
    local domain = type(text) == 'string' and #text >= 8 and access.memory:pointer(text, 0) or nil
    if type(seat) ~= 'number' or type(domain) ~= 'number' or domain == 0 then return nil end
    local entry = spec.entry   -- 条目号取规格常量（config.inputs.form_b.entry，唯一出处）；席位只进基址层。
    local slot, base = string.format('%d', entry), domain + spec.base_rva + seat * spec.avatar_stride + spec.block_off
    return 'READFACE seat=' .. string.format('%d', seat) .. ' chain=ok mg_domain=0x' .. string.format('%x', domain) ..
        ' game_domain=0x' .. string.format('%x', access.game + spec.base_rva + seat * spec.avatar_stride + spec.block_off) ..
        ' mg_entry' .. slot .. '_addr=0x' .. string.format('%x', base + entry * spec.entry_size) .. ' ' .. held_text('mg_held' .. slot, self.source, entry) ..
        ' prod_addr=0x' .. string.format('%x', base + entry * spec.entry_size) .. ' ' .. held_text('prod_held', self.source, entry) .. ' mute=' .. tostring(self.source ~= nil and self.source.mute == true)
end

-- 证据行文本：状态、原因（含 instant 的拒绝清单原词）、调用数，以及 instant 已回读的弹药值与本次采用容量（零额外读面）；状态面自检行（STATEFACE）逐跳结果＋原始值＋逐键席位结果；窗口边沿行（WINDOW open/close）带当帧 wield0／mag_ammo（取自与 AFTERWRITE 同源的字段面），用于分离装备瞬态伪窗——三处均只观测、不进判据。
local STATEFACE_KEYS = { 'reloading', 'mag_reserve', 'mag_ammo', 'reload_stage', 'ability_running' }
local COMPONENT_KEYS = { 'mag', 'rounds', 'reload', 'wieldable', 'ability' }
local function word(text, offset)
    local a, b, c, d = string.byte(text, offset + 1, offset + 4)
    return d ~= nil and (a + b * 0x100 + c * 0x10000 + d * 0x1000000) or nil
end
-- rounds 管理器 map 占用计数：窗口 open 帧触发重采（去重豁免）；三态分离（立规 2）＝unset 未算／done 已算／其余本轮失败（失败不缓存、原因随行渲染）；全分支显式 if/else（立规 1）；只读，不碰 access 解码原语。
local function rounds_occupied(self)
    if self.rounds_state == 'done' and type(self.rounds_occ) == 'number' then return self.rounds_occ end
    local access, native = self.access, self.config.native
    local layout = nil
    if type(native) == 'table' then layout = native.map end
    if access == nil or access.memory == nil or layout == nil then return nil, NONE end
    if type(access.specs) ~= 'table' or type(access.game) ~= 'number' then return nil, NONE end
    local spec = nil
    for index = 1, #access.specs do
        if access.specs[index].key == 'rounds' then spec = access.specs[index] end
    end
    if type(spec) ~= 'table' then return nil, NONE end
    local memory = access.memory
    local manager = memory:pointer(memory:read(access.game + spec.global, POINTER_WIDTH) or '', 0)
    if type(manager) ~= 'number' then return nil, 'no-manager' end
    local base = memory:pointer(memory:read(manager + spec.map, POINTER_WIDTH) or '', 0)
    local capacity = word(memory:read(manager + spec.map + layout.capacity, 4) or '', 0)
    local empty = word(memory:read(manager + spec.map + layout.empty, 4) or '', 0)
    if type(base) ~= 'number' then return nil, 'no-rows' end
    if type(capacity) ~= 'number' or capacity <= 0 then return nil, 'no-capacity' end
    local text = memory:read(base, capacity * POINTER_WIDTH)
    if type(text) ~= 'string' then return nil, 'no-rows' end
    local seen = 0
    for slot = 0, capacity - 1 do
        if word(text, slot * POINTER_WIDTH) ~= empty then seen = seen + 1 end
    end
    self.rounds_state, self.rounds_occ = 'done', seen
    return seen
end

local function abandon_reason(self, snap)   -- 落窗按压后写路径未被调用时的拒因（逐项枚举，只取本件可观测面）
    if snap == nil then return 'no-snapshot' end
    if self.trigger ~= nil and self.trigger.instant_enabled ~= true then return 'disabled' end
    if self.instant == nil then return 'no-write-face' end
    return 'no-hit'
end

local function post_values(self)   -- 写后快照读数（纯诊断）：按当前行句柄重读字段面，读不到即回 nil（不以 0 冒充）
    local rows = nil
    if self.trigger ~= nil then rows = self.trigger.rows end
    if rows == nil or self.access == nil then return nil end
    return self.access.fields(rows)
end

-- 写后六步采样：步 3／4／5＝相对写帧 +0x1E／+0x5A／+0x87 帧；步 1＝写成功当帧、步 2＝次帧、步 6＝wield0 变化后首帧（无固定偏移）。
local AFTER_OFFSET = { 0, 1, 0x1E, 0x5A, 0x87 }

local function after_line(self, values, step)   -- 写后快照行：六步采样各一行；只观测，不进判据、不做补救性写入
    return 'AFTERWRITE step=' .. string.format('%d', step) ..
        ' ' .. number_or('reloading', field_of(values, 'reloading')) ..
        ' ' .. number_or('reload_stage', field_of(values, 'reload_stage')) ..
        ' ' .. number_or('ability_running', field_of(values, 'ability_running')) ..
        ' ' .. number_or('mag_ammo', field_of(values, 'mag_ammo')) ..
        ' ' .. number_or('mag_reserve', field_of(values, 'mag_reserve')) ..
        ' ' .. number_or('wield0', field_of(values, 'wield_0')) .. stamp(self, false)
end

-- 写后采样推进（每帧一次）：按帧偏移逐步落行，窗口关闭不终止；步 6 由 wield0 变化触发（先于步 5 则当帧落行、序列继续）。
local function after_sample(self)
    if self.after_active ~= true then return end
    local frames = type(self.ticker) == 'table' and self.ticker.frames or nil
    if type(frames) ~= 'number' then self.after_active, self.after_watch = false, false; return end
    local values, delta, step = post_values(self), frames - self.after_frame, self.after_next
    while step <= #AFTER_OFFSET do
        if delta < AFTER_OFFSET[step] then break end
        note(self, after_line(self, values, step))
        step = step + 1
    end
    self.after_next = step
    local now = field_of(values, 'wield_0')
    if type(now) == 'number' and now ~= self.after_wield0 then
        self.after_watch = false
        note(self, after_line(self, values, 6))
    end
    if self.after_next > #AFTER_OFFSET and self.after_watch ~= true then self.after_active = false end
end

local function stateface(self)
    local access = self.access
    if access == nil then return nil end
    local slots, why = access.slots(); local walked, values, rows = access.walked, nil, nil
    local chain = walked ~= nil and 'ok' or text_or(why or 'no-chain')
    local slots_state = slots ~= nil and 'ok' or 'map-absent'
    local comps_state = 'map-absent'
    local entity = slots ~= nil and (slots.wield_0 or slots.wield_1) or nil
    if slots ~= nil then
        local comps_why; rows, comps_why = access.components(entity)
        if rows ~= nil then comps_state, values = 'ok', access.fields(rows) else comps_state = text_or(comps_why) end
    end
    local marks = {}
    for index = 1, #COMPONENT_KEYS do
        local seat = nil
        if type(rows) == 'table' then seat = rows.seats[COMPONENT_KEYS[index]] end
        marks[index] = seat ~= nil and 'ok' or 'absent'
    end
    local raw = field_of(rows, 'slots_raw')
    local occ, occ_why = nil, nil
    if rows == nil or rows.seats == nil or rows.seats.rounds == nil then occ, occ_why = rounds_occupied(self) end
    local occ_text = NONE
    if type(occ) == 'number' then occ_text = string.format('%d', occ)
    elseif type(occ_why) == 'string' then occ_text = occ_why end
    local state_at, state_at_text = field_of(walked, 'state_at'), NONE
    if type(state_at) == 'number' then state_at_text = '0x' .. string.format('%x', state_at) end
    local text = 'STATEFACE seat=' .. text_or(field_of(walked, 'seat')) .. ' chain=' .. chain ..
        ' slots=' .. slots_state .. ' comps=' .. comps_state .. ' entity=' .. text_or(entity) ..
        ' keys=' .. table.concat(marks, '|') .. ' ' .. number_or('raw0', field_of(raw, 1)) .. ' ' .. number_or('raw1', field_of(raw, 2)) ..
        ' rounds_occ=' .. occ_text .. ' state_at=' .. state_at_text
    local complete = values ~= nil
    for index = 1, #STATEFACE_KEYS do
        local value = field_of(values, STATEFACE_KEYS[index])
        if type(value) ~= 'number' then complete = false end
        text = text .. ' ' .. number_or(STATEFACE_KEYS[index], value)
    end
    return text .. ' fields=' .. (complete and 'ok' or 'incomplete') .. ' ' .. number_or('wield0', field_of(values, 'wield_0')),
        chain .. '|' .. slots_state .. '|' .. comps_state .. '|' .. (complete and 'ok' or 'incomplete')
end

local function write_line(self, last, capacity)
    local status, reason, calls = NONE, NONE, NONE
    if last ~= nil then status, reason, calls = text_or(last.status), text_or(last.reason), text_or(last.calls) end
    return 'WRITE status=' .. status .. ' reason=' .. reason .. ' calls=' .. calls ..
        ' ' .. number_or('reserve', field_of(last, 'reserve')) .. ' ' .. number_or('ammo', field_of(last, 'ammo')) ..
        ' ' .. number_or('capacity', capacity) .. stamp(self, true)
end

-- 写面 api：照 vendored 文件头的既有用法构造（bingus_memory.new(runtime) → bingus_write.extend(api)）；本件不实现任何写，构造失败即 api=nil，instant 自会落到 no-write-face。
local function build_api(modules)
    local memory_lib = modules['game/vendor/bingus_memory']
    local runtime_lib = modules['game/vendor/bingus_runtime']
    if type(memory_lib) ~= 'table' or type(memory_lib.new) ~= 'function' then return nil end
    local ok, api = pcall(memory_lib.new, runtime_lib)
    if not ok or type(api) ~= 'table' then return nil end
    local write_lib = modules['game/vendor/bingus_write']
    if type(write_lib) == 'table' and type(write_lib.extend) == 'function' then
        pcall(write_lib.extend, api)
    end
    return api
end

-- request：reload.send 注入点的唯一实现。返回 true 才算交回成功；nil 会让 send 判 unavailable。
function wiring.request(self)
    self.press_reason = nil
    -- 写入锁存：同一次换弹成功写过一次即不再接受第二次（写后幻影窗里的命中会白扣一匣备弹），锁存到本轮真正结束。
    if self.latched == true then
        self.press_reason = 'already-written'
        return nil
    end
    local instant = self.instant
    if instant == nil then return nil end
    local last = instant.complete(instant, self.snap)
    note(self, write_line(self, last, self.capacity))
    if last ~= nil and last.rolled_back == true then
        note(self, 'ROLLBACK reason=' .. text_or(last.reason) .. ' ' .. number_or('reserve', last.reserve) .. ' ' .. number_or('ammo', last.ammo) .. stamp(self, true))
    end
    if last ~= nil and last.status == 'written' then
        self.latched, self.latched_at = true, nil
        local values, ticker = post_values(self), self.ticker
        local frames = type(ticker) == 'table' and ticker.frames or nil
        note(self, after_line(self, values, 1))
        self.after_active, self.after_watch = false, false
        if type(frames) == 'number' then
            self.after_active, self.after_frame, self.after_next = true, frames, 2
            local wield0 = field_of(values, 'wield_0')
            if type(wield0) == 'number' then self.after_wield0, self.after_watch = wield0, true end
        end
    end
    return last ~= nil and last.status == 'written', last ~= nil and last.status or NONE
end

-- 每帧一次（帧路径调用）：只收本帧入参、不新建闭包、非边沿与非按键帧不落行。
-- 次序纪律：必须排在入口按下判定之前（本帧快照先进本件，reload.send 才用得上；滞后一帧会把上帧弹量当写入依据）。
function wiring.track(self, snap, in_window, was, pressed, ticker)
    self.snap, self.ticker = snap, ticker
    if self.press_reason ~= nil then
        note(self, 'WRITE status=abandoned reason=' .. self.press_reason .. stamp(self, true))
        self.press_reason = nil
    end
    after_sample(self)
    if was ~= true and in_window == true then
        self.window_at = type(self.ticker) == 'table' and self.ticker.seconds or nil
        local edge = post_values(self)
        note(self, 'WINDOW open ' .. number_or('wield0', field_of(edge, 'wield_0')) ..
            ' ' .. number_or('mag_ammo', field_of(edge, 'mag_ammo')) .. stamp(self, true))
        self.rounds_state, self.stateface_key, self.stateface_done = 'unset', nil, false
    elseif was == true and in_window ~= true then
        capture(self, snap)
        local edge = post_values(self)
        note(self, 'WINDOW close ' .. number_or('capacity', self.capacity) ..
            ' ' .. number_or('wield0', field_of(edge, 'wield_0')) ..
            ' ' .. number_or('mag_ammo', field_of(edge, 'mag_ammo')) .. stamp(self, true))
    end
    -- 锁存解除：窗口连续关闭超过延续阈值才算本轮换弹结束（写后幻影窗关窗不足 0.1 秒即重开，单帧为假不足以解除）。
    if in_window == true then
        self.latched_at = nil
    elseif self.latched == true then
        local seconds = type(self.ticker) == 'table' and self.ticker.seconds or nil
        if type(seconds) == 'number' then
            if self.latched_at == nil then
                self.latched_at = seconds
            elseif seconds - self.latched_at > self.hold then
                self.latched, self.latched_at = false, nil
            end
        end
    end
    local registry = self.observed
    if registry ~= nil then
        if registry.ability == true and self.seen_ability ~= true then
            self.seen_ability = true; note(self, 'OBSERVED ability=0' .. stamp(self, false))
        end
        if registry.stage == true and self.seen_stage ~= true then
            self.seen_stage = true; note(self, 'OBSERVED stage=0' .. stamp(self, false))
        end
    end
    if in_window == true and pressed == true then
        note(self, 'PRESS window ' .. number_or('capacity', self.capacity) .. stamp(self, true))
        self.press_reason = abandon_reason(self, snap)
    end
    if self.readface_done ~= true then
        local line = readface(self)
        if line ~= nil then
            self.readface_done = true
            note(self, line .. stamp(self, false))
        end
    end
    if self.stateface_done ~= true then
        local face, key = stateface(self)
        if face ~= nil and key ~= self.stateface_key then
            self.stateface_key = key
            if key == 'ok|ok|ok|ok' then self.stateface_done = true end
            note(self, face .. stamp(self, false))
        end
    end
end

function wiring.describe(self)
    return { gate = self.gate == true, taken = self.taken == true, capacity = self.capacity, reason = self.reason, snap = self.snap ~= nil }
end

function wiring.new(deps)
    deps = deps or {}
    local modules, config = deps.modules, deps.config
    if type(modules) ~= 'table' or type(config) ~= 'table' or type(config.instant) ~= 'table' then return nil, 'no-config' end
    local hold = 0
    if type(config.bar) == 'table' and type(config.bar.hold_seconds) == 'number' then hold = config.bar.hold_seconds end
    local object = { modules = modules, config = config, logger = deps.logger, access = deps.access,
                     trigger = deps.trigger, observed = deps.observed, snap = nil, taken = false,
                     capacity = nil, instant = nil, gate = false, reason = nil, log = nil, press_reason = nil,
                     seen_ability = false, seen_stage = false, ticker = nil, window_at = nil, source = nil,
                     readface_done = false, after_active = false, after_frame = nil, after_next = nil,
                     after_wield0 = nil, after_watch = false, rounds_state = 'unset', rounds_occ = nil,
                     latched = false, latched_at = nil, hold = hold }
    object.stateface_key, object.stateface_done = nil, false
    setmetatable(object, { __index = wiring })          -- 帧路径按 wired.track(...) 点调用，实例侧给出模块面
    local source_lib = modules['game/source_formb']
    object.source = type(source_lib) == 'table' and type(source_lib.new) == 'function' and source_lib.new(deps.access, config.inputs.form_b) or nil   -- 只读副本：自检行取样用
    local log_lib = modules['log']
    if type(log_lib) == 'table' and type(log_lib.info) == 'function' then
        object.log = function(line) log_lib.info(deps.logger, line) end
    end
    local instant_lib = modules['game/instant']
    if type(instant_lib) ~= 'table' or type(instant_lib.new) ~= 'function' then return object, 'no-instant' end
    -- 模块在场即授权构型，闸门只此一轴：默认包不含本文件，故这一支永不进入，总闸维持 false。
    config.instant.enabled = true
    local api = build_api(modules); object.api = api
    local instance, reason = instant_lib.new({ config = config.instant, native = config.native,
        read = function(address, size) return read_at(object, address, size) end, locate = function(kind) return locate(object, kind) end,
        api = api, write_lib = modules['game/vendor/bingus_write'], log = function(line) note(object, line) end })
    object.instant, object.reason, object.gate = instance, reason, instance ~= nil   -- 闸门只在实例造出来时才开；构造失败即维持关闭（安全降级，与默认构建同态）
    if type(deps.trigger) == 'table' then
        deps.trigger.request = function() return wiring.request(object) end
    end
    return object, reason
end

return wiring
