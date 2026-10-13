"""MOD-MEM 读面闸门（vendored 哈希、地址域归一、模块基址折数字）。

用法：py -3.11 -B mod/tests/memory_check.py
环境变量 MOD_SRC 指向被测的 mod/ 目录（默认本文件上一级）；MOD_MEM_UPSTREAM 可选，指上游仓库根
（默认 MOD_SRC 的上一级），用于 vendored 逐字节比对；上游不在本次比对范围时明确打印跳过行，不静默
通过。判据：A3 module_base 折数字、交出/收回两方向地址域归一、vendored 三件对哈希与上游逐字节一致、
读面不导出任何写方法。基准一律写成门内字面量或独立复算，不读回被测源码的同值自比。
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

# 门内基准：vendored 三件的放置路径与上游来源（逐字节副本，缺一即判红）。
# 上游来源为上游仓库内的相对路径；与 build.py 的 VENDOR_TABLE 互为独立登记，两处必须一致。
VENDOR_EXPECTED = {
    'game/vendor/bingus_runtime': 'BingusSharedRuntime/runtime/bingus_runtime.lua',
    'game/vendor/bingus_memory': 'BingusSharedRuntime/runtime/bingus_memory.lua',
    'game/vendor/bingus_write': 'BingusSharedLoader/bingus_write.lua',
}
BINGUS_WRITE_SHA = '9a0a217811d109418faebb2af8804bfb8301b0eeeb1e6b5bc020fdacbd596160'
READ_NAMES_EXPECTED = ('available', 'read', 'pointer', 'module_base', 'reason_text', 'stats')
REASONS_EXPECTED = ('bingus_runtime copy missing', 'bingus_memory copy missing',
                    'bingus_memory returned no api')
OUT_ANCHOR = "ffi.cast('const void *'"
IN_ANCHOR = 'self.api.address('
BANNED_IN_READER = ('write_batch', 'write_ready', 'WriteProcessMemory')


def sha256_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def function_body(text, header):
    """截出某个顶层函数的正文：从 header 起，到第一个顶格 end 为止。"""
    lines = text[text.index(header):].splitlines()
    body = [lines[0]]
    for line in lines[1:]:
        body.append(line)
        if line == 'end':
            break
    return '\n'.join(body)


def load_build(mod_root):
    path = mod_root / 'build.py'
    if not path.is_file():
        raise RuntimeError('被测源码树里没有 build.py：' + str(path))
    spec = importlib.util.spec_from_file_location('memory_gate_build', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_cases(mod_root, cases):
    """驱动与本门主题相关的桩用例（其余用例属其他门与并行线，不在这里耦合）。"""
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


def check_vendored(gate, src_root, build, upstream_root):
    """vendored 三件：对 build 的哈希登记、对门内独立基准、对上上游逐字节。"""
    table = dict(build.VENDOR_TABLE)
    gate.check(sorted(table) == sorted(VENDOR_EXPECTED),
               'vendored 登记表覆盖三件（实得 %s）' % ','.join(sorted(table)))
    for key, origin in sorted(VENDOR_EXPECTED.items()):
        entry = table.get(key)
        gate.check(entry is not None and entry[0] == origin,
                   'vendored %s 的上游来源登记为 %s' % (key, origin))
        path = src_root / (key + '.lua')
        gate.check(path.is_file(), 'vendored 副本存在：%s.lua' % key)
        if not path.is_file():
            continue
        actual = sha256_file(path)
        gate.check(entry is not None and actual == entry[1],
                   'vendored %s 哈希与 build 登记一致' % key)
        if key == 'game/vendor/bingus_write':
            gate.check(actual == BINGUS_WRITE_SHA, 'vendored 写面对门内基准哈希')
        source = upstream_root / origin
        if not source.is_file():
            print('ok: 上游不在本次比对范围，跳过逐字节（%s）' % origin)
            continue
        gate.check(source.read_bytes() == path.read_bytes(),
                   'vendored %s 与上游 %s 逐字节一致' % (key, origin))
    gate.check('game/vendor/bingus_write.lua' in tuple(build.AUTHORIZE_ONLY_MODULES),
               'vendored 写面只登记在授权模块序里')
    gate.check('game/vendor/bingus_write.lua' not in tuple(build.MODULE_ORDER),
               'vendored 写面不在默认模块序里')


def check_reader(gate, src_root, build):
    """读面：地址域两方向归一、模块基址折数字、零写方法、失败原因成串、行数与洁净度。"""
    path = src_root / 'game' / 'memory.lua'
    if not path.is_file():
        gate.check(False, '读面文件存在：game/memory.lua')
        return None
    raw = path.read_bytes()
    text = raw.decode('utf-8')
    gate.check(raw.count(b'\r') == 0 and raw[:1] != b'\xef' and b'\x00' not in raw,
               '读面无 CR／BOM／NUL')
    gate.check(text.count('\n') <= build.MODULE_LINE_LIMIT,
               '读面行数不超过模块硬上限 %d' % build.MODULE_LINE_LIMIT)
    gate.check(OUT_ANCHOR in function_body(text, 'local function as_const_pointer('),
               '交出方向把 number/cdata 归一成 const void *')
    gate.check(IN_ANCHOR in function_body(text, 'local function method_pointer('),
               '收回方向把指针折成 Lua 数字（外部只见 number）')
    base_body = function_body(text, 'local function method_module_base(')
    gate.check(IN_ANCHOR in base_body and '.module(' in base_body,
               'A3 模块基址由 module 句柄折成数字')
    names = re.search(r'local names = \{([^}]*)\}', text)
    declared = tuple(re.findall(r"'([A-Za-z_]\w*)'", names.group(1))) if names else ()
    gate.check(declared == READ_NAMES_EXPECTED,
               '读面公开方法集与门内基准一致（%s）' % ','.join(declared))
    gate.check(not any(name.startswith('write') for name in declared),
               '读面公开方法里没有任何写方法')
    for banned in BANNED_IN_READER:
        gate.check(banned not in text, '读面全文不含写面符号 %s' % banned)
    for reason in REASONS_EXPECTED:
        gate.check(reason in text, '初始化失败原因成串：%s' % reason)
    return declared


def main():
    gate = Gate()
    given = os.environ.get('MOD_SRC')
    mod_root = Path(given).resolve() if given else DEFAULT_MOD
    if not mod_root.is_dir() or not (mod_root / 'src').is_dir() or not (mod_root / 'tests').is_dir():
        print('FAIL: MOD_SRC 指向的源码树不存在或缺 src/ 与 tests/：' + str(mod_root))
        print('failures=1')
        return 1
    src_root = mod_root / 'src'
    upstream = os.environ.get('MOD_MEM_UPSTREAM')
    upstream_root = Path(upstream).resolve() if upstream else mod_root.parent
    print('gate: MOD-MEM 源码树=%s 上游=%s' % (mod_root, upstream_root))

    build = load_build(mod_root)
    check_vendored(gate, src_root, build, upstream_root)
    check_reader(gate, src_root, build)

    # L1 用例集：两方向归一与 module_base 的行为由它见证（含空转检查：用例真的跑了）
    code, output = run_cases(mod_root, ('test_memory.lua',))
    gate.check(code == 0 and 'FAIL: ' not in output, 'memory 用例全绿（地址域归一由它见证，exit %d）' % code)
    passed = case_passed(output)
    gate.check(passed >= 20, 'memory 用例真的跑了（passed=%d，需 ≥20，防静默空跑）' % passed)

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
