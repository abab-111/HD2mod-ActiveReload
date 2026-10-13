-- 桩用例（不是门，见 mod/tests/README 角色表）：形态 B 取址（先解引用 avatar_manager 全局指针）、
-- 条目号取常量 entry（与席位无关）、一次读足、H3 纪律与规格指纹。
return function(env)
    local formb = env.modules['game/source_formb']
    if not (type(formb) == 'table' and type(formb.new) == 'function') then
        env.check(false, 'game/source_formb 模块未加载')
        return
    end

    local GAME, RVA, MANAGER = 16777216, 53636384, 33554432
    local BASE, STRIDE, BLOCK, WIDTH, ENTRY, HELD_AT = 336, 686828, 7016, 32, 10, 8
    local SEAT = 1
    local spec = {
        base_rva = BASE, avatar_stride = STRIDE, block_off = BLOCK, entry_size = WIDTH, entry = ENTRY,
        index_map = 'direct', held_at = HELD_AT, held_kind = 'f32', mute_windows = 3,
        hold_epsilon = 0, entry_scale = 97,
    }
    -- 期望地址在用例里独立复算（不得读回被测函数的结果再自比）。
    -- 域＝管理器指针（GAME+RVA 处解引用所得），席位只参与 base 层，条目号＝常量 ENTRY。
    local block_start = MANAGER + BASE + SEAT * STRIDE + BLOCK
    local entry_address = block_start + ENTRY * WIDTH
    local seat_only_address = block_start + SEAT * WIDTH

    local function u64(value)
        local text, rest = '', value
        for _ = 1, 8 do
            text = text .. string.char(rest % 0x100)
            rest = math.floor(rest / 0x100)
        end
        return text
    end

    local seen, held = {}, 1
    local function entry_bytes(value)
        local cells = {}
        for index = 1, WIDTH do cells[index] = 0 end
        if value ~= 0 then cells[HELD_AT + 1], cells[HELD_AT + 2], cells[HELD_AT + 3], cells[HELD_AT + 4] =
            0, 0, 128, 63 end
        local out = {}
        for index = 1, WIDTH do out[index] = string.char(cells[index]) end
        return table.concat(out)
    end
    local memory = {
        read = function(_, address, size)
            seen.last_address, seen.last_size = address, size
            if address == GAME + RVA then
                seen.domain_read = address
                return u64(MANAGER)
            end
            if seen.fail then return nil end
            seen.entry_address = address
            return entry_bytes(held)
        end,
        pointer = function(_, text, offset)
            if text == nil or #text < offset + 8 then return nil end
            local value, scale = 0, 1
            for index = 1, 8 do
                value = value + string.byte(text, offset + index) * scale
                scale = scale * 0x100
            end
            return value
        end,
    }
    local access = { game = GAME, chain = { avatar_manager = RVA }, walked = { seat = SEAT }, memory = memory }

    local object, reason = formb.new(access, spec)
    env.check(type(object) == 'table', 'formb.new 应返回对象（原因 ' .. tostring(reason) .. '）')
    if type(object) ~= 'table' then return end
    env.equal(object.name, 'form_b', '源名应为 form_b')

    -- ① 取址：先解引用 avatar_manager（域＝管理器），条目号＝常量 entry（与席位无关）
    held = 1
    env.equal(object:level(), true, 'held 非零应判按下')
    env.equal(seen.domain_read, GAME + RVA, '必须先读 game_base + chain.avatar_manager 处的全局指针')
    env.equal(seen.entry_address, entry_address, '条目地址应等于独立复算值（域＝管理器 + 常量条目号）')
    env.check(seen.entry_address ~= seat_only_address, '条目号不得退化成席位号')
    env.equal(seen.last_size, WIDTH, '必须一次读足 entry_size 字节')

    held = 0
    env.equal(object:level(), false, 'held 等于 hold_epsilon 应判未按下')
    env.equal(object.mute, true, '未按下应记静音')

    seen.fail = true
    local value, why = object:level()
    env.check(value == nil and why == 'read-failed',
              '条目读失败必须回 nil 与 read-failed，不得以 false 冒充（H3）')
    env.check(object.faults > 0, '读失败应计入 faults，不得静默')
    seen.fail = false
    seen.fail = nil

    -- ② 块基址不成立一律 block-unresolved，绝不外推地址。
    local broken = formb.new({ game = nil, chain = { avatar_manager = RVA }, walked = { seat = SEAT }, memory = memory }, spec)
    local edge, edge_why = broken:level()
    env.check(edge == nil and edge_why == 'block-unresolved', '缺基址应回 block-unresolved')
    local no_chain = formb.new({ game = GAME, walked = { seat = SEAT }, memory = memory }, spec)
    local chain_edge, chain_why = no_chain:level()
    env.check(chain_edge == nil and chain_why == 'block-unresolved',
              '缺 chain.avatar_manager 应回 block-unresolved，不得落到 game.dll 头部域')
    env.equal(formb.new({}, spec), nil, '缺 memory 面应回 nil')
    env.equal(formb.new(access, nil), nil, '缺 spec 应回 nil')

    -- ③ 规格指纹：有 jit 的 bit 才可算；L1 纯 Lua 解释器如实回 no-digest，不伪造。
    local keys = env.modules['config'].inputs.form_b_fingerprint_keys
    local digest, digest_why = formb.digest(spec, keys)
    if type(rawget(_G, 'jit')) == 'table' then
        env.equal(digest, '8c041a6e', '指纹应与 config.inputs.form_b_fingerprint 一致')
    else
        env.equal(digest_why, 'no-digest', '无 bit 库时应如实回 no-digest')
    end

    -- ④ describe 只读快照字段齐备，且不含写面。
    local view = object:describe()
    env.equal(view.name, 'form_b', 'describe 应回源名')
    env.equal(view.entry_size, WIDTH, 'describe 应回读宽')
    env.equal(view.held_kind, 'f32', 'describe 应回取值形态')
    env.check(view.write == nil and view.write_batch == nil, '描述表不得含写面字段')
end
