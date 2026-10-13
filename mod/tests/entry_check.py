"""MOD-ENTRY 装配级闸门（字面基准与错键判据）。

用法：py -3.11 -B mod/tests/entry_check.py
环境变量 MOD_SRC 指向被测的 mod/ 目录（默认本文件所在目录的上一级）；变异测试在临时副本上调用本门。
基准一律写成门内字面量或独立复算，绝不读回被测源码的同一个值来自比。判据：A1 形态 B 规格指纹三方
一致＋A7 双口径复算、A6 两套模块序、B1 取源键链、B3 惩罚参数链、禁自比、access.lua 定向解冻基准（≤310 行）。
"""

import hashlib
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_MOD = HERE.parent

# 门内字面基准：形态 B 规格十一键、原生链十四项、两套模块序（不复算自源码，避免读回自比）。
FORM_B_EXPECTED = {
    'base_rva': 336, 'avatar_stride': 686828, 'block_off': 7016, 'entry_size': 32, 'entry': 10,
    'index_map': 'direct', 'held_at': 8, 'held_kind': 'f32', 'mute_windows': 3,
    'hold_epsilon': 0.0, 'entry_scale': 97,
}
FORM_B_HEX_EXPECTED = {
    'base_rva': '0x150', 'avatar_stride': '0xA7AEC', 'block_off': '0x1B68',
    'entry_size': '0x20', 'entry': '0xA', 'held_at': '0x8', 'entry_scale': '0x61',
}
FINGERPRINT_EXPECTED = '8c041a6e'
CHAIN_EXPECTED = {
    'player_manager': 53634152, 'local_unit': 936, 'entity_owner': 54968216, 'owner_map': 15871688,
    'owner_entities': 15937304, 'entity_stride': 24, 'entity_id': 8, 'unit_id': 12, 'avatar_manager': 53636384,
    'avatar_map': 248, 'avatar_count': 108, 'avatar_controller': 5495040, 'controller_stride': 4664,
    'identity': 2948,
}
MODULE_ORDER_EXPECTED = (
    'config.lua', 'log.lua', 'options.lua', 'core/zone.lua', 'core/timeline.lua', 'core/state.lua',
    'game/reload.lua', 'game/access.lua', 'game/input.lua', 'game/time.lua', 'game/vendor/bingus_runtime.lua',
    'game/driver.lua', 'game/vendor/bingus_memory.lua', 'game/memory.lua', 'game/source_formb.lua', 'ui/bar.lua',
)
AUTHORIZE_ONLY_EXPECTED = ('game/instant.lua', 'game/wiring.lua', 'game/logsink.lua',
                           'game/vendor/bingus_write.lua')
ACCESS_PIN_PREFIX = 'a8f1fefc46694995'
CASE_FILES_EXPECTED = ('test_zone.lua', 'test_timeline.lua', 'test_state.lua', 'test_options.lua',
                       'test_reload.lua', 'test_access.lua', 'test_memory.lua', 'test_source_formb.lua',
                       'test_readface.lua', 'test_stateface.lua', 'test_instant.lua', 'test_wiring.lua',
                       'test_logsink.lua', 'test_driver.lua', 'test_entry.lua', 'test_bar.lua')
# 禁自比：期望值一侧出现这些被测面名字的调用即判不合格。
UNDER_TEST_NAMES = ('block', 'native', 'poll', 'level', 'view', 'snapshot', 'send', 'press', 'resolve', 'describe',
                    'read', 'pointer', 'module_base', 'complete', 'arm', 'digest', 'ready_to_fire', 'window', 'edge',
                    'duration', 'interrupt', 'begin', 'frame', 'activate', 'sample', 'step', 'draw', 'configure',
                    'submit')
EXPECTED_SIDE_CALL = re.compile(r'^\s*env\.equal\(\s*[^,]+,\s*([A-Za-z_][A-Za-z0-9_.:]*)\s*\(')
EXPECTED_MODULE = re.compile(r'^\s*env\.equal\([^,]+,.*env\.modules')
NUMBER = re.compile(r'^-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?$')

def lua_number(text):
    """Lua 数字字面量 → Python 数字（十六进制栏与十进制栏各自独立解析）。"""
    text = text.strip()
    if text.lower().startswith('0x'):
        return int(text, 16)
    if not NUMBER.match(text):
        return None
    if '.' in text or 'e' in text.lower():
        value = float(text)
        return int(value) if value.is_integer() else value
    return int(text)


def lua_tostring(value):
    """按 Lua tostring 的口径渲染：布尔另有写法，整数值不带小数点。"""
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)) and float(value).is_integer():
        return '%d' % int(value)
    return str(value)


def block_text(text, header):
    """按大括号配对截出以 header 开头的那张表。"""
    start = text.index('{', text.index(header))
    depth = 0
    for index in range(start, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise ValueError('括号不配对：' + header)


LINE = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$')
HEX_NOTE = re.compile(r'--\s*(0x[0-9A-Fa-f]+)')


def parse_fields(text):
    """解析一张扁平表：回 ({键: 值}, {键: 十六进制栏原始文本})；行内先剥注释再取「键 = 值」。"""
    values, hexes = {}, {}
    for line in text.splitlines():
        code, note = line.split('--')[0].strip(), HEX_NOTE.search(line)
        match = LINE.match(code)
        if match is None:
            continue
        name, raw = match.group(1), match.group(2).strip().rstrip(',').strip()
        if raw.startswith('{'):
            continue
        if raw.startswith("'") and raw.endswith("'"):
            values[name] = raw[1:-1]
        elif raw in ('true', 'false'):
            values[name] = raw == 'true'
        else:
            number = lua_number(raw)
            if number is None:
                continue
            values[name] = number
        if note is not None:
            hexes[name] = note.group(1)
    return values, hexes


def digest(spec, keys):
    text = ''.join('%s=%s;' % (key, lua_tostring(spec[key])) for key in keys)
    return hashlib.sha256(text.encode('utf-8')).hexdigest()[:8], text


def load_build(mod_root):
    path = mod_root / 'build.py'
    if not path.is_file():
        raise RuntimeError('被测源码树里没有 build.py：' + str(path))
    spec = importlib.util.spec_from_file_location('entry_gate_build', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_cases(mod_root, cases):
    env = dict(os.environ)
    env['PYTHONIOENCODING'] = 'utf-8'
    command = [sys.executable, '-B', str(mod_root / 'tests' / 'compile_check.py'), '--run']
    for name in cases:
        command += ['--case', name]
    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8',
                           env=env, cwd=str(mod_root.parent))
    return result.returncode, (result.stdout or '') + (result.stderr or '')


def case_passed(output):
    """从 L1 汇总行里取断言条数；取不到（或失败非零）回 -1，便于空转检查判红。"""
    match = re.search(r'TOTAL passed=(\d+) failed=(\d+)', output)
    if not match or match.group(2) != '0':
        return -1
    return int(match.group(1))


class Gate:
    def __init__(self):
        self.failures = []

    def check(self, condition, message):
        print(('ok: ' if condition else 'FAIL: ') + message)
        if not condition:
            self.failures.append(message)


def scan_self_comparisons(tests_root):
    """扫桩用例的期望值一侧：要求期望值只能是字面量或独立桩返回值。

    env.equal 的第二个实参若调用了被测面（本文件定义的助手或 env.modules 上的方法），
    等于拿被测面的输出去比它自己；调用外部桩（桩内存、桩写面）不算自比。
    """
    found = []
    local_definition = re.compile(r'local\s+(?:function\s+)?([A-Za-z_]\w*)\s*[(=]')
    for path in sorted(tests_root.glob('test_*.lua')):
        text = path.read_text(encoding='utf-8')
        defined = set(local_definition.findall(text))
        for number, line in enumerate(text.splitlines(), 1):
            match = EXPECTED_SIDE_CALL.match(line)
            if match is not None:
                callee = match.group(1).split('.')[-1].split(':')[-1]
                if callee in UNDER_TEST_NAMES and ('env.modules' in line or callee in defined):
                    found.append('%s:%d 期望值一侧调用被测面 %s（疑似自比）' % (path.name, number, callee))
            elif EXPECTED_MODULE.match(line) is not None:
                found.append('%s:%d 期望值一侧引用被测模块表（疑似自比）' % (path.name, number))
    return found


def main():
    gate = Gate()
    given = os.environ.get('MOD_SRC')
    mod_root = Path(given).resolve() if given else DEFAULT_MOD
    if not mod_root.is_dir() or not (mod_root / 'src').is_dir() or not (mod_root / 'tests').is_dir():
        print('FAIL: MOD_SRC 指向的源码树不存在或缺 src/ 与 tests/：' + str(mod_root))
        print('failures=1')
        return 1
    src_root, tests_root = mod_root / 'src', mod_root / 'tests'
    print('gate: MOD-ENTRY 源码树=%s' % mod_root)

    config_text = (src_root / 'config.lua').read_text(encoding='utf-8')
    build = load_build(mod_root)

    access = src_root / 'game' / 'access.lua'
    access_hash = hashlib.sha256(access.read_bytes()).hexdigest()[:16] if access.is_file() else ''
    access_limit = build.MODULE_LINE_LIMIT_OVERRIDE.get('game/access.lua', build.MODULE_LINE_LIMIT)
    gate.check(access_hash == ACCESS_PIN_PREFIX and access.is_file()
               and access.read_text(encoding='utf-8').count('\n') <= access_limit,
               'access.lua 保持定向解冻基准（前缀 %s）且不超过单件硬上限 %d'
               % (ACCESS_PIN_PREFIX, access_limit))

    # A1 形态 B 规格指纹：三方一致（门内基准 / 独立复算 / config 声明）
    spec, spec_hex = parse_fields(block_text(config_text, 'config.inputs.form_b ='))
    keys = re.findall(r"'([A-Za-z_][A-Za-z0-9_]*)'",
                      block_text(config_text, 'config.inputs.form_b_fingerprint_keys ='))
    declared = re.search(r"config\.inputs\.form_b_fingerprint\s*=\s*'([0-9a-f]+)'", config_text)
    ready = keys == list(FORM_B_EXPECTED) and all(key in spec for key in keys)
    recomputed, text = digest(spec, keys) if ready else (None, '')
    gate.check(declared is not None, 'config 里声明了形态 B 规格指纹')
    gate.check(keys == list(FORM_B_EXPECTED), '指纹键序与门内基准一致（%s）' % ','.join(keys))
    gate.check(recomputed is not None, '十一键齐备，可独立复算指纹')
    gate.check(recomputed == FINGERPRINT_EXPECTED,
               '独立复算的指纹等于门内基准 %s（实得 %s）' % (FINGERPRINT_EXPECTED, recomputed))
    gate.check(declared is not None and declared.group(1) == FINGERPRINT_EXPECTED,
               'config 声明的指纹等于门内基准')
    gate.check(recomputed == FINGERPRINT_EXPECTED and declared is not None and digest(spec, keys)[1] == text,
               '拼串可复现（%s）' % text.strip())

    # A7 双口径：规格与原生链的十进/十六进制两栏各自独立解析后相等
    for name, expected in sorted(FORM_B_HEX_EXPECTED.items()):
        gate.check(spec_hex.get(name) == expected and lua_number(spec_hex[name]) == FORM_B_EXPECTED[name],
                   '规格 %s 十六进制栏 %s ＝ 十进制 %s（实得 %s）'
                   % (name, expected, FORM_B_EXPECTED[name], spec_hex.get(name)))
    for name, expected in sorted(FORM_B_EXPECTED.items()):
        gate.check(spec.get(name) == expected, '规格 %s 等于门内基准 %s（实得 %s）' % (name, expected, spec.get(name)))
    chain, chain_hex = parse_fields(block_text(config_text, 'chain = {'))
    for name, expected in sorted(CHAIN_EXPECTED.items()):
        gate.check(chain.get(name) == expected, '原生链 %s 等于门内基准（实得 %s）' % (name, chain.get(name)))
    for name, hexed in sorted(chain_hex.items()):
        gate.check(lua_number(hexed) == chain.get(name),
                   '原生链 %s 两栏同值（十进制 %s ＝ 十六进制 %s）' % (name, chain.get(name), hexed))

    # B1 取源键链：config 的源名 → 取源注册表 → 源名到模块键的映射 → 模块序
    inputs, _ = parse_fields(block_text(config_text, 'config.inputs = {'))
    name = inputs.get('source')
    if isinstance(name, str) and len(name) > 1 and name[0] in ('"', "'"):
        name = name[1:-1]
    gate.check(name == 'form_b', 'config.inputs.source 为 form_b（实得 %s）' % name)
    registry = dict(re.findall(r'([A-Za-z_]\w*)\s*=\s*(true|false)',
                               block_text(config_text, 'sources = {')))
    gate.check(registry.get(name) == 'true', '取源注册表把 %s 登记为 true' % name)
    mapping = dict(re.findall(r"([A-Za-z_]\w*)\s*=\s*'(game/source_[A-Za-z0-9_]+)'",
                              (src_root / 'game' / 'input.lua').read_text(encoding='utf-8')))
    key = mapping.get(name)
    gate.check(key is not None, '取源层给出 %s 到模块键的显式映射' % name)
    gate.check(key is not None and (key + '.lua') in tuple(build.MODULE_ORDER),
               '模块表里有对应的源模块 %s.lua' % key)
    for other, value in sorted(registry.items()):
        gate.check(other == name or value == 'false', '未实现的候选 %s 必须显式登记为 false' % other)

    # B3 惩罚参数链：来源键到消费键的映射必须显式存在
    entry_text = (src_root / 'active_reload.lua').read_text(encoding='utf-8')
    gate.check('penalty_percent = { default = 0.20' in config_text, '来源键 penalty_percent 默认 0.20')
    gate.check('penalty_per_miss = settings.penalty_percent' in entry_text,
               '装配期把来源键显式映射到消费键 penalty_per_miss')
    gate.check('deps.cycle.penalty_per_miss' in (src_root / 'core' / 'state.lua').read_text(encoding='utf-8'),
               '状态机确实消费 penalty_per_miss')

    # A6 模块表键与两套模块序
    gate.check(tuple(build.MODULE_ORDER) == MODULE_ORDER_EXPECTED, '默认模块序与门内基准逐键一致')
    gate.check(tuple(build.AUTHORIZE_ONLY_MODULES) == AUTHORIZE_ONLY_EXPECTED, '写路径模块与门内基准一致')
    gate.check(tuple(build.AUTHORIZED_MODULE_ORDER) == MODULE_ORDER_EXPECTED + AUTHORIZE_ONLY_EXPECTED,
               '授权模块序＝默认 ＋ 写路径')
    gate.check('game/instant.lua' not in tuple(build.MODULE_ORDER), 'instant.lua 默认不纳入构建')

    # A7 日志端点面：配置键合规、端点件只走加载器公开面、两件无内部编号与称谓
    log_block = block_text(config_text, 'config.log = {')
    log_name = re.search(r"name\s*=\s*'([^']*)'", log_block)
    gate.check(log_name is not None and re.fullmatch(r'[\w-]+\.log', log_name.group(1)) is not None,
               'config.log.name 是加载器认的合法文件名（实得 %s）' % (log_name and log_name.group(1)))
    sink_text = (src_root / 'game' / 'logsink.lua').read_text(encoding='utf-8')
    gate.check('open_log' in sink_text and 'io.open(' not in sink_text,
               '日志端点件只走加载器的 open_log，不自开文件')
    gate.check('game/logsink.lua' not in tuple(build.MODULE_ORDER) and 'game/logsink.lua' in AUTHORIZE_ONLY_EXPECTED,
               '日志端点件默认不纳入构建、只在授权构建登记')
    for label, path in (('日志端点件', src_root / 'game' / 'logsink.lua'),
                        ('接线件', src_root / 'game' / 'wiring.lua')):
        leaked = re.findall(r'任务单|裁定|决策者|执行者|变异体|§|\bR-\d+\b|WRITE_PATH_MODULES',
                            path.read_text(encoding='utf-8'))
        gate.check(not leaked, '%s零内部编号与称谓（%s）' % (label, '；'.join(leaked) if leaked else '无'))

    # A8 帧驱动接线面：驱动件在共享模块序里、入口的装配与尾部挂链字面锚齐备、
    # 挂链只走随包运行时件的守卫接口，且由 L1 用例真跑见证「宿主每帧链确实驱动本系统」。
    driver_text = (src_root / 'game' / 'driver.lua').read_text(encoding='utf-8')
    gate.check('game/driver.lua' in tuple(build.MODULE_ORDER)
               and 'game/driver.lua' not in AUTHORIZE_ONLY_EXPECTED,
               '帧驱动件在共享模块序里（默认与授权两构型都装配）')
    gate.check("local driver_lib = modules['game/driver']" in entry_text, '入口装配段按模块键取到驱动件')
    gate.check('system.driver = driver_lib ~= nil and driver_lib.new({' in entry_text,
               '入口装配段按模块在场自判构造驱动件')
    gate.check('if system.driver ~= nil then system.driver.attach(system.driver) end' in entry_text,
               '入口尾把系统挂到宿主每帧链')
    gate.check('runtime.guard' in driver_text and 'rawset(' not in driver_text,
               '挂链只走随包运行时件的守卫接口，不自造全局链')
    gate.check('write_batch' not in driver_text, '帧驱动件不含写调用（只挂链，不读不写）')

    # A9 诊断面（READFACE）在场且只观测：所在件不得含任何写调用或全局改写（行为面纪律）
    wiring_text = (src_root / 'game' / 'wiring.lua').read_text(encoding='utf-8')
    gate.check('READFACE ' in wiring_text, '诊断面在场（授权接线件落 READFACE 行）')
    gate.check('write_batch' not in wiring_text and 'rawset(' not in wiring_text,
               '诊断面所在件不含写调用与全局改写（诊断行只观测）')

    # A10 两处修复的字面锚：位字段按数字 0/1 折布尔、形态 B 取址先解引用全局指针、条目号取常量
    reload_text = (src_root / 'game' / 'reload.lua').read_text(encoding='utf-8')
    gate.check('reloading = fields.reloading == 1,' in reload_text,
               'reloading 位字段按数字 0/1 折成布尔（F1 回归锚）')
    gate.check('ability_running = fields.ability_running == 1,' in reload_text,
               'ability_running 位字段按数字 0/1 折成布尔（F2 回归锚）')
    formb_text = (src_root / 'game' / 'source_formb.lua').read_text(encoding='utf-8')
    gate.check('access.chain.avatar_manager' in formb_text and 'access.memory:read(access.game + rva, 8)' in formb_text,
               '形态 B 取址先解引用全局指针（F3 回归锚）')
    gate.check('local index = spec.entry' in formb_text,
               '块内条目号取常量 entry，不按席位折出（F4 回归锚）')

    # A11 默认构型不受本轮新增面影响：授权独有件一律不进默认模块序、默认入口文本不含诊断面
    gate.check(all(relative not in tuple(build.MODULE_ORDER)
                   for relative in ('game/instant.lua', 'game/wiring.lua', 'game/logsink.lua')),
               '默认模块序不含任何授权独有件（默认组装字节由 compile_check 复跑比对）')
    gate.check('READFACE ' not in entry_text, '默认入口文本不含诊断面')

    # 禁自比 + 用例清单
    found = scan_self_comparisons(tests_root)
    gate.check(not found, '桩用例期望值一侧没有调用被测面（%s）' % ('；'.join(found) if found else '无自比'))
    case_files = tuple(sorted(path.name for path in tests_root.glob('test_*.lua')))
    gate.check(case_files == tuple(sorted(CASE_FILES_EXPECTED)),
               '用例文件清单与基准一致（%s）' % ','.join(case_files))

    # L1 用例集：源取址与输入面行为由它见证（含空转检查：用例真的跑了）
    code, output = run_cases(mod_root, ('test_source_formb.lua',))
    gate.check(code == 0 and 'FAIL: ' not in output, 'source_formb 用例全绿（源取址与输入面由它见证，exit %d）' % code)
    passed = case_passed(output)
    gate.check(passed >= 15, 'source_formb 用例真的跑了（passed=%d，需 ≥15，防静默空跑）' % passed)

    # L1 用例集：帧驱动接线面由它见证（含空转检查：用例真的跑了）
    code, output = run_cases(mod_root, ('test_driver.lua',))
    gate.check(code == 0 and 'FAIL: ' not in output, 'driver 用例全绿（帧驱动接线由它见证，exit %d）' % code)
    driven = case_passed(output)
    gate.check(driven >= 30, 'driver 用例真的跑了（passed=%d，需 ≥30，防静默空跑）' % driven)

    # L1 用例集：读面修复（数字位字段／解引用／条目号）与诊断面由它见证（含空转检查：用例真的跑了）
    code, output = run_cases(mod_root, ('test_readface.lua',))
    gate.check(code == 0 and 'FAIL: ' not in output, 'readface 用例全绿（读面修复与诊断面由它见证，exit %d）' % code)
    readface = case_passed(output)
    gate.check(readface >= 25, 'readface 用例真的跑了（passed=%d，需 ≥25，防静默空跑）' % readface)

    # L1 用例集：入口装配面与绘制面由它见证（含空转检查：用例真的跑了）
    code, output = run_cases(mod_root, ('test_entry.lua',))
    gate.check(code == 0 and 'FAIL: ' not in output, 'entry 用例全绿（装配面与绘制面由它见证，exit %d）' % code)
    assembled = case_passed(output)
    gate.check(assembled >= 40, 'entry 用例真的跑了（passed=%d，需 ≥40，防静默空跑）' % assembled)

    # L1 用例集：条几何、可见性与绘制端由它见证（含空转检查：用例真的跑了）
    code, output = run_cases(mod_root, ('test_bar.lua',))
    gate.check(code == 0 and 'FAIL: ' not in output, 'bar 用例全绿（几何、可见性与绘制端由它见证，exit %d）' % code)
    bars = case_passed(output)
    gate.check(bars >= 25, 'bar 用例真的跑了（passed=%d，需 ≥25，防静默空跑）' % bars)

    # L1 用例集：取值收敛与游戏内菜单接入由它见证（含空转检查：用例真的跑了）
    code, output = run_cases(mod_root, ('test_options.lua',))
    gate.check(code == 0 and 'FAIL: ' not in output, 'options 用例全绿（取值收敛与菜单接入由它见证，exit %d）' % code)
    optioned = case_passed(output)
    gate.check(optioned >= 25, 'options 用例真的跑了（passed=%d，需 ≥25，防静默空跑）' % optioned)

    print('failures=%d' % len(gate.failures))
    print('result: %s' % ('通过' if not gate.failures else '失败 %d 项' % len(gate.failures)))
    return 0 if not gate.failures else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as error:  # 门自身出错也必须落 FAIL 行，绝不崩栈
        print('FAIL: 门自身出错：%s: %s' % (type(error).__name__, error))
        print('failures=1')
        sys.exit(1)
