"""MOD-MUTANT 变异测试驱动（每条变异必须被它的见证门抓住）。

用法：py -3.11 -B mod/tests/mutant_check.py
环境变量 MOD_SRC 指向被测的 mod/ 目录（默认本文件上一级）。每条变异在 mod/ 的临时整拷贝上注入，
跑完即删，源码本体只读。顺序：先做对照组（干净副本上每个见证门必须 exit 0），再做空转自检
（MOD_SRC 指向不存在的目录必须报错退出），最后逐条断言见证门变红。锚点缺失（命中次数 ≠ 1）、
门静默通过都算失败，绝不静默跳过。
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_MOD = HERE.parent

if hasattr(sys.stdout, 'reconfigure'):  # 控制台默认 GBK，变异名里的 ①②… 落不下去
    sys.stdout.reconfigure(encoding='utf-8')

WITNESS_GATES = ('write_gate_check.py', 'entry_check.py', 'memory_check.py')

# （名称、相对 mod/ 的路径、锚点原文、替换原文、见证门）；路径里的字符串一律按 UTF-8 字节注入。
MUTANTS = (
    ('① 写面泄漏：默认构建的写面登记只剩 instant',
     'build.py', "WRITE_PATH_MODULES = ('game/instant', 'game/vendor/bingus_write')",
     "WRITE_PATH_MODULES = ('game/instant',)", 'write_gate_check.py'),
    ('①b 假写依赖混进默认构建源树',
     'src/game/source_formb.lua', 'local formb = {}',
     'local formb = {}\nlocal mutant_call = api.write_batch(0, 0, {})  -- 变异体：假写依赖',
     'write_gate_check.py'),
    ('② 取源键错写 formb', 'src/config.lua', "source = 'form_b',", "source = 'formb',",
     'entry_check.py'),
    ('③ 索引口径退化只留 seat', 'src/game/source_formb.lua',
     'local index = spec.entry',
     'local index = seat -- 变异体：索引口径退化', 'entry_check.py'),
    ('④ 读宽度少 1 字节', 'src/game/source_formb.lua', 'local width = spec.entry_size',
     'local width = spec.entry_size - 1 -- 变异体：少读 1 字节', 'entry_check.py'),
    ('⑤ 交出方向不再归一化', 'src/game/memory.lua',
     "return ffi.cast('const void *', value)", 'return value -- 变异体：交出方向不再归一化',
     'memory_check.py'),
    ('⑤b 收回方向不再归一化', 'src/game/memory.lua', 'return self.api.address(value)',
     'return value -- 变异体：收回方向不再归一化', 'memory_check.py'),
    ('⑥ 地址步长改用被禁值 687340', 'src/config.lua', 'avatar_stride = 686828,',
     'avatar_stride = 687340,', 'entry_check.py'),
    ('⑦ 按住阈值改成非零 0.5', 'src/config.lua', 'hold_epsilon = 0.0,', 'hold_epsilon = 0.5,',
     'entry_check.py'),
    ('⑧ 装配回显拿被测面自比', 'tests/test_entry.lua',
     "env.equal(self_report, 'form_b@8c041a6e', '取源自证等于源名加规格指纹')",
     "env.equal(self_report, env.modules['game/input'].block(env.modules['game/input']), '取源自证')",
     'entry_check.py'),
    ('⑨ 回滚被跳过（部分成功当成功）', 'src/game/instant.lua',
     'local rolled, roll_calls = issue(self, mag, ability, reload, running, reserve, ammo, stage)',
     'local rolled, roll_calls = true, 0 -- 变异体：回滚被跳过', 'write_gate_check.py'),
    ('⑩ 窗口自闸被绕过', 'src/game/instant.lua',
     "if snap.reloading ~= true or type(snap.mag_reserve) ~= 'number' or snap.mag_reserve <= 0 then",
     'if false then -- 变异体：窗口外也写', 'write_gate_check.py'),
    ('⑪ 写调用扫描正则失效', 'build.py', "WRITE_CALL_PATTERN = re.compile(r'\\bwrite_batch\\s*\\(')",
     "WRITE_CALL_PATTERN = re.compile(r'\\bwrite_never\\s*\\(')", 'write_gate_check.py'),
    ('⑫ 定向解冻件 access.lua 越界再改', 'src/game/access.lua', 'return access',
     'return access -- 变异体：解冻件越界被改', 'entry_check.py'),
    ('⑬ 授权装配不注入 request（接线缺失）', 'src/game/wiring.lua',
     'deps.trigger.request = function() return wiring.request(object) end',
     '-- 变异体：接线缺失，唯一实现点不注入', 'write_gate_check.py'),
    ('⑭ 写面证据行被删（写结果不留行）', 'src/game/wiring.lua',
     'note(self, write_line(self, last, self.capacity))',
     '-- 变异体：写面证据行被删', 'write_gate_check.py'),
    ('⑮ 容量未采集也可写（容量下限被放行）', 'src/game/instant.lua',
     "self.config.capacity_source == 'snapshot' and snap.mag_ammo_max",
     'snap.mag_ammo_max or 30 -- 变异体：容量未采集也可写', 'write_gate_check.py'),
    ('⑯ 授权装配不构造日志端点（落盘缺失）', 'src/active_reload.lua',
     "and modules['game/logsink'].open(config.log) or nil",
     'and nil or nil -- 变异体：不构造日志端点', 'write_gate_check.py'),
    ('⑰ 证据行丢失时序字段（时间读数不可用）', 'src/game/wiring.lua',
     "    local text = ' t=' .. (seconds ~= nil and string.format('%.3f', seconds) or NONE) ..",
     "    local text = ' t=' .. tostring(NONE) .. -- 变异体：时序字段失真", 'write_gate_check.py'),
    ('⑱ 默认构型也构造日志端点（默认包不纯净）', 'src/active_reload.lua',
     "    local log_sink = (type(modules) == 'table' and type(modules['game/logsink']) == 'table')",
     '    local log_sink = (type(modules) == \'table\') -- 变异体：不检日志端点件在场',
     'write_gate_check.py'),
    ('⑲ 入口尾不挂宿主链（接线缺失）', 'src/active_reload.lua',
     'if system.driver ~= nil then system.driver.attach(system.driver) end',
     '-- 变异体：接线缺失，入口尾不挂链', 'entry_check.py'),
    ('⑳ 构造守卫却不真装，仍报就绪', 'src/game/driver.lua',
     'local ready, problem = pcall(guard.install, guard)',
     'local ready, problem = true, nil -- 变异体：不真装守卫，直接报就绪', 'entry_check.py'),
    ('㉑ 手写全局链绕过官方守卫（生态安全）', 'src/game/driver.lua',
     "    local made, guard = pcall(runtime.guard, { name = driver.NAME, log = self.log, env = env,\n"
     "        step = function(delta) return driver.step(self, delta) end,\n"
     "        stop = function(reason) return driver.stop(self, reason) end })",
     "    local made, guard = pcall(function()\n"
     "        rawset(env, 'update', function(delta) return driver.step(self, delta) end)\n"
     "        return { install = function() return true end }\n"
     "    end) -- 变异体：手写全局链，绕过官方守卫", 'entry_check.py'),
    ('㉒ 帧函数空转（挂链不驱动）', 'src/game/driver.lua',
     '    local phase = self.frame(delta)',
     '    local phase = nil -- 变异体：帧函数空转', 'entry_check.py'),
    ('㉓ 位字段口径改回布尔比较（读面失效）', 'src/game/reload.lua',
     'reloading = fields.reloading == 1,',
     'reloading = fields.reloading == true, -- 变异体：数字位字段被当布尔比较', 'entry_check.py'),
    ('㉔ 形态 B 取址不解引用全局指针', 'src/game/source_formb.lua',
     'local rva = access.chain ~= nil and access.chain.avatar_manager or nil',
     'local rva = nil -- 变异体：不解引用 avatar_manager', 'entry_check.py'),
    ('㉕ 条目号按席位折出（flat 口径复活）', 'src/game/source_formb.lua',
     'local index = spec.entry',
     'local index = spec.entry_scale * seat + spec.entry -- 变异体：条目号按席位折出', 'entry_check.py'),
    ('㉖ 诊断行被删（读面自检不留行）', 'src/game/wiring.lua',
     'note(self, line .. stamp(self, false))',
     '-- 变异体：诊断行被删', 'entry_check.py'),
    ('㉗ 监测位占位符口径改回布尔比较', 'src/game/reload.lua',
     'ability_running = fields.ability_running == 1,',
     'ability_running = fields.ability_running == true, -- 变异体：数字位字段被当布尔比较',
     'entry_check.py'),
    ('㉚ 状态面自检行被删（失败态不留行）', 'src/game/wiring.lua',
     'note(self, face .. stamp(self, false))',
     '-- 变异体：状态面自检行被删', 'entry_check.py'),
    ('㉛ 状态面去重失效（同因重复落行）', 'src/game/wiring.lua',
     'if face ~= nil and key ~= self.stateface_key then',
     'if face ~= nil and key ~= nil then -- 变异体：去重失效', 'entry_check.py'),
    ('㉜ 状态面字段原始值被抹平（常量 0 冒充）', 'src/game/wiring.lua',
     "text = text .. ' ' .. number_or(STATEFACE_KEYS[index], value)",
     "text = text .. ' ' .. number_or(STATEFACE_KEYS[index], 0) -- 变异体：原始值被抹平", 'entry_check.py'),
    ('㉝ 逐键容错被移除（单键缺席即整体失败）', 'src/game/access.lua',
     "if found ~= true then return nil, 'map-absent' end",
     "return nil, 'map-absent' -- 变异体：全缺判定被短路，容错移除", 'entry_check.py'),
    ('㉞ 缺席席位守卫被移除（nil 席位直进解码）', 'src/game/access.lua',
     'if mag ~= nil then read_array(self, mag, 1, out); read_array(self, mag, 2, out); read_pool(self, mag, rows.entity, out) end',
     'read_array(self, mag, 1, out); read_array(self, mag, 2, out); read_pool(self, mag, rows.entity, out) -- 变异体：缺席守卫被移除',
     'entry_check.py'),
    ('㉟ rounds 管理器占用计数被删（H2/H3 判别面失明）', 'src/game/wiring.lua',
     "    if rows == nil or rows.seats == nil or rows.seats.rounds == nil then occ, occ_why = rounds_occupied(self) end",
     "    occ, occ_why = nil, nil -- 变异体：占用计数被删",
     'entry_check.py'),
    ('㊱ 状态面传入实体号被抹（逐键结果无从归属）', 'src/game/wiring.lua',
     "' slots=' .. slots_state .. ' comps=' .. comps_state .. ' entity=' .. text_or(entity) ..",
     "' slots=' .. slots_state .. ' comps=' .. comps_state .. ' entity=' .. text_or(nil) .. -- 变异体：实体号打印被删",
     'entry_check.py'),
    ('㊲ rounds 占用成功不落缓存（三态分离失效，逐帧重算）', 'src/game/wiring.lua',
     "    self.rounds_state, self.rounds_occ = 'done', seen",
     "    self.rounds_occ = seen -- 变异体：成功不落缓存，三态分离失效",
     'entry_check.py'),
    ('㊳ 窗口 open 不重置状态面缓存（窗口期重采失效）', 'src/game/wiring.lua',
     "        self.rounds_state, self.stateface_key, self.stateface_done = 'unset', nil, false",
     "        -- 变异体：窗口期不重置状态面缓存，重采失效",
     'entry_check.py'),
    ('㊴ 落窗按压弃写不落拒因行（写入率无从判读）', 'src/game/wiring.lua',
     "        note(self, 'WRITE status=abandoned reason=' .. self.press_reason .. stamp(self, true))",
     "        -- 变异体：拒因行被删",
     'entry_check.py'),
    ('㊵ 写后快照行被删（当帧 step=1）', 'src/game/wiring.lua',
     '        note(self, after_line(self, values, 1))',
     '        -- 变异体：写后快照行被删（step=1）',
     'entry_check.py'),
    ('㊶ 写后采样行被删（帧偏移步不落行）', 'src/game/wiring.lua',
     '        note(self, after_line(self, values, step))',
     '        -- 变异体：写后采样行被删',
     'write_gate_check.py'),
    ('㊷ 写后采样帧偏移表被改（步 3 提前落行）', 'src/game/wiring.lua',
     'local AFTER_OFFSET = { 0, 1, 0x1E, 0x5A, 0x87 }',
     'local AFTER_OFFSET = { 0, 1, 0, 0x5A, 0x87 } -- 变异体：步 3 偏移被抹',
     'write_gate_check.py'),
    ('㊸ 写后采样推进被删（帧偏移驱动失效）', 'src/game/wiring.lua',
     '    after_sample(self)',
     '    -- 变异体：写后采样推进被删',
     'write_gate_check.py'),
    ('㊹ wield0 变化触发被删（步 6 不落行）', 'src/game/wiring.lua',
     "    if type(now) == 'number' and now ~= self.after_wield0 then",
     '    if false then -- 变异体：wield0 变化触发被删',
     'write_gate_check.py'),
    ('㊺ 写后快照行缺 reloading 字段', 'src/game/wiring.lua',
     "        ' ' .. number_or('reloading', field_of(values, 'reloading')) ..",
     "        ' ' ..",
     'write_gate_check.py'),
    ('㊻ 换弹阶段标志补写被删（写 C 不落，出口缺陷不修）', 'src/game/instant.lua',
     "    local ok_c, done_c, landed_c = pcall(self.batch, reload, stage.offset + stage.width,\n"
     "                                         { { stage.offset, bytes_of(stage.kind, stage_new) } })",
     "    local ok_c, done_c, landed_c = true, true, nil -- 变异体：写 C 被删",
     'write_gate_check.py'),
    ('㊼ 静音窗一次性标志被删（计数停在阈值时重发）', 'src/active_reload.lua',
     "            if observed.mute == mute_windows and observed.mute_reported ~= true then\n"
     "                observed.mute_reported = true\n"
     "                log.info(logger, 'INPUT-B-MUTE windows=' .. tostring(observed.mute))",
     "            if observed.mute == mute_windows then\n"
     "                log.info(logger, 'INPUT-B-MUTE windows=' .. tostring(observed.mute))",
     'write_gate_check.py'),
    ('㊽ 窗口边沿行扩字段被删（伪窗判别器失明）', 'src/game/wiring.lua',
     "        note(self, 'WINDOW open ' .. number_or('wield0', field_of(edge, 'wield_0')) ..\n"
     "            ' ' .. number_or('mag_ammo', field_of(edge, 'mag_ammo')) .. stamp(self, true))",
     "        note(self, 'WINDOW open' .. stamp(self, true)) -- 变异体：窗口扩字段被删",
     'write_gate_check.py'),
    ('㊾ 账目算式回退跨单位相减（备弹按补差多发多扣）', 'src/game/instant.lua',
     '    local reserve_new = reserve - 1',
     '    local reserve_new = reserve - (ammo_new - ammo) -- 变异体：账目算式回退跨单位相减',
     'write_gate_check.py'),
    ('㊿ 备弹守卫被删（零备弹照写）', 'src/game/instant.lua',
     "    if reserve < 1 then return result(self, 'abandoned', nil, false, 'no-reserve') end",
     "    if false then return result(self, 'abandoned', nil, false, 'no-reserve') end -- 变异体：备弹守卫被删",
     'write_gate_check.py'),
    ('51 包络守卫被删（非本武器容量照写）', 'src/game/instant.lua',
     "    if capacity ~= EXPECTED_CAPACITY then",
     "    if false then -- 变异体：包络守卫被删",
     'write_gate_check.py'),
    ('52 绘制面被删（条从不提交）', 'src/active_reload.lua',
     '        return bar.draw(sink, layout, bar.palette(config.color, cycle.misses), config.bar.border)',
     '        return false -- 变异体：绘制面被删',
     'entry_check.py'),
    ('53 命中不消失（本轮结束后条仍在）', 'src/ui/bar.lua',
     '    return cycle.phase == sweeping',
     '    return true -- 变异体：命中不消失',
     'entry_check.py'),
    ('54 按错不变灰红（惩罚无从看见）', 'src/ui/bar.lua',
     "    if type(misses) == 'number' and misses > 0 then",
     '    if false then -- 变异体：按错不变灰红',
     'entry_check.py'),
    ('55 条偏移越界不回落（可调项失守）', 'src/config.lua',
     '    bar_offset = { default = 0.10, min = 0.05, max = 0.20 },',
     '    bar_offset = { default = 0.10, min = 0.05, max = 1.0 }, -- 变异体：越界不回落',
     'entry_check.py'),
    ('56 菜单越界值不回落（照抄进设置表）', 'src/options.lua',
     '    settings[item.key] = options.pick(spec[item.key], ratio)',
     '    settings[item.key] = ratio or spec[item.key].default -- 变异体：菜单越界值不回落',
     'entry_check.py'),
    ('57 条位置方向回退（跑到准星上方）', 'src/ui/bar.lua',
     '    local y = screen.height * box.anchor - screen.width * view.offset',
     '    local y = screen.height * box.anchor + screen.width * view.offset -- 变异体：位置方向回退',
     'entry_check.py'),
    ('58 短窗延续被删（三段条又分开）', 'src/ui/bar.lua',
     '    if seconds <= state.release_at then return true end',
     '    if false then return true end -- 变异体：短窗延续被删',
     'entry_check.py'),
    ('59 写入锁存被删（幻影窗二次扣匣）', 'src/game/wiring.lua',
     '    if self.latched == true then',
     '    if false then -- 变异体：写入锁存被删',
     'write_gate_check.py'),
    ('60 语言回落只看前缀（Steam 中文码不认）', 'src/options.lua',
     "        if code == 'schinese' or code == 'tchinese' then return 'zh' end",
     "        if false then return 'zh' end -- 变异体：语言回落只看前缀",
     'entry_check.py'),
    ('61 合一阈值回退（段间闪断又分开）', 'src/config.lua',
     '    hold_seconds = 3.2,',
     '    hold_seconds = 2.0, -- 变异体：合一阈值回退',
     'entry_check.py'),
    ('62 游标宽度回退（实心加粗失守）', 'src/ui/bar.lua',
     '            width = marker,',
     '            width = border, -- 变异体：游标宽度回退',
     'entry_check.py'),
    ('63 游标色值回退（与白命中区重叠隐形）', 'src/config.lua',
     '    marker = { 0.95, 0.80, 0.35 },',
     '    marker = { 0.95, 0.95, 0.95 }, -- 变异体：游标色值回退',
     'entry_check.py'),
)


def run_gate(root, gate):
    """在被测树上跑一件见证门（门脚本取本仓库的一套，被测树由 MOD_SRC 指定）。"""
    env = dict(os.environ)
    env['MOD_SRC'] = str(root)
    env['PYTHONIOENCODING'] = 'utf-8'
    result = subprocess.run([sys.executable, '-B', str(HERE / gate)], capture_output=True,
                            text=True, encoding='utf-8', env=env, cwd=str(DEFAULT_MOD.parent))
    return result.returncode, (result.stdout or '') + (result.stderr or '')


def inject(root, relative, anchor, replacement):
    """按字节注入（build.py 强制 LF，文本模式会把它改写成 CRLF）；锚点必须恰好命中一次。"""
    path = root / relative
    if not path.is_file():
        return '变异目标不存在：' + relative
    raw = path.read_bytes()
    needle = anchor.encode('utf-8')
    hits = raw.count(needle)
    if hits != 1:
        return '锚点命中 %d 次（须恰好 1 次）：%s' % (hits, relative)
    path.write_bytes(raw.replace(needle, replacement.encode('utf-8')))
    return None


def main():
    failures = []

    def check(condition, message):
        print(('ok: ' if condition else 'FAIL: ') + message)
        if not condition:
            failures.append(message)

    given = os.environ.get('MOD_SRC')
    base = Path(given).resolve() if given else DEFAULT_MOD
    if not base.is_dir() or not (base / 'src').is_dir() or not (base / 'tests').is_dir():
        print('FAIL: MOD_SRC 指向的变异基准树不存在或缺 src/ 与 tests/：' + str(base))
        print('failures=1')
        return 1
    print('gate: MOD-MUTANT 基准树=%s 变异数=%d' % (base, len(MUTANTS)))

    # 对照组：干净基准上每个见证门必须全绿（否则变异结论不可信）
    for gate in WITNESS_GATES:
        code, output = run_gate(base, gate)
        check(code == 0 and 'FAIL: ' not in output, '对照组：干净树上 %s exit 0（实得 %d）' % (gate, code))

    # 空转自检：MOD_SRC 指向不存在的目录时每件门都必须报错退出，不得静默通过
    missing = Path(tempfile.mkdtemp(prefix='w6_missing_')) / 'nope'
    for gate in WITNESS_GATES:
        code, output = run_gate(missing, gate)
        check(code != 0 and 'FAIL: ' in output,
              '空转自检：%s 在缺源码树时非 0 退出（实得 %d）' % (gate, code))
    shutil.rmtree(str(missing.parent), ignore_errors=True)

    # 逐条变异：临时整拷贝 → 字节注入 → 见证门必须变红 → 删除副本
    for order, (name, relative, anchor, replacement, gate) in enumerate(MUTANTS, 1):
        root = Path(tempfile.mkdtemp(prefix='w6_mutant_')) / 'mod'
        try:
            shutil.copytree(str(base), str(root))
            problem = inject(root, relative, anchor, replacement)
            if problem is not None:
                check(False, '%s：%s' % (name, problem))
                continue
            code, output = run_gate(root, gate)
            check(code != 0 and 'FAIL: ' in output,
                  '%d/%d 必红：%s（见证门 %s，exit %d）' % (order, len(MUTANTS), name, gate, code))
        finally:
            shutil.rmtree(str(root.parent), ignore_errors=True)

    print('mutants=%d failures=%d' % (len(MUTANTS), len(failures)))
    print('result: %s' % ('通过' if not failures else '失败 %d 项' % len(failures)))
    return 0 if not failures else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as error:  # 驱动自身出错也必须落 FAIL 行，绝不崩栈
        print('FAIL: 驱动自身出错：%s: %s' % (type(error).__name__, error))
        print('failures=1')
        sys.exit(1)
