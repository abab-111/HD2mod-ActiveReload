"""MOD-WRITE 写面闸门（构建期判据）：默认产物零写路径文件、写批次上限与回滚记账。

用法：py -3.11 -B mod/tests/write_gate_check.py
环境变量 MOD_SRC 指向被测的 mod/ 目录（默认本文件所在目录的上一级）。变异测试会在模/ 的临时副本上
调用本门，因此所有判断都必须以 MOD_SRC 为准，不许回落到本文件自己所在的那份源码。

本门做五件事，任何一项不成立都落 FAIL 行并非 0 退出：
  ① 整棵源树写调用扫描：任何写调用只许出现在 WRITE_PATH_MODULES 登记的文件里（不限于模块清单）；
  ② 假写依赖证明：往一个「默认构建会打包、但不在写面登记里」的源文件插一行假写调用，默认构建必须硬失败，
     且把 WRITE_PATH_MODULES 收窄成只剩 instant.lua 之后仍必须硬失败（证明判据不是「instant.lua 缺席」）；
  ③ 两套产物物理隔离：授权构建写进 releases/ 必须硬失败，默认构建写进 authorized/ 同样硬失败；
  ④ 写批次上限与回滚记账由 L1 用例（test_instant.lua）见证，本门驱动该用例集并要求全绿；
  ⑤ 写路径接线与容量武装由 L1 用例（test_wiring.lua）见证：授权装配把 request 注入唯一实现点、
    容量未采集即拒、写面证据行齐备（含回读弹药值）——接线、证据行、容量采集都是行为面，
     该用例全程用真帧路径驱动。
"""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_MOD = HERE.parent

# 与 build.py 的常量口径一致；这里写成字面量，避免「读回自比」。
WRITE_PATH_MODULES = ('game/instant', 'game/vendor/bingus_write')
WRITE_CALL_PATTERN = re.compile(r'\bwrite_batch\s*\(')
FAKE_WRITE_ANCHOR = 'local formb = {}'
FAKE_WRITE_LINE = 'local mutant_probe = api.write_batch(0, 0, {})  -- 变异体：假写依赖'
SELF_SUFFIX = 'self'


def load_build(mod_root):
    """从被测源码树加载 build.py；载入失败即失败，绝不回落到别处的 build.py。"""
    path = mod_root / 'build.py'
    if not path.is_file():
        raise RuntimeError('被测源码树里没有 build.py：' + str(path))
    spec = importlib.util.spec_from_file_location('build_under_test_' + str(abs(hash(str(path)))), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scan_write_sites(src_root):
    """扫整棵源树的 .lua（不限于模块清单），回「相对路径:行号」。

    判据是「默认产物里不存在任何写路径文件」，所以这里必须看全部源文件：只要将来多出任何
    一个没登记的写依赖，这条扫描立刻命中。
    """
    sites = []
    for path in sorted(src_root.rglob('*.lua')):
        text = path.read_text(encoding='utf-8')
        for number, line in enumerate(text.splitlines(), 1):
            if WRITE_CALL_PATTERN.search(line):
                sites.append('%s:%d' % (path.relative_to(src_root).as_posix(), number))
    return sites


def run_build(mod_root, arguments):
    """在临时工作目录里跑一次构建，返回 (退出码, stdout, stderr)。"""
    env = dict(os.environ)
    env['PYTHONIOENCODING'] = 'utf-8'
    result = subprocess.run([sys.executable, '-B', str(mod_root / 'build.py')] + [str(a) for a in arguments],
                            capture_output=True, text=True, encoding='utf-8', env=env,
                            cwd=str(mod_root.parent))
    return result.returncode, result.stdout or '', result.stderr or ''


def run_cases(mod_root, cases):
    """驱动 L1 用例集里与本门主题相关的桩用例（其余用例属并行线，不在这里耦合）。"""
    env = dict(os.environ)
    env['PYTHONIOENCODING'] = 'utf-8'
    command = [sys.executable, '-B', str(mod_root / 'tests' / 'compile_check.py'), '--run']
    for name in cases:
        command += ['--case', name]
    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8',
                            env=env, cwd=str(mod_root.parent))
    return result.returncode, (result.stdout or '') + (result.stderr or '')


def case_passed(output):
    """从 L1 汇总行里取断言条数；取不到返回 -1，便于空转检查判红。"""
    match = re.search(r'TOTAL passed=(\d+) failed=(\d+)', output)
    if not match:
        return -1
    return int(match.group(1)) if match.group(2) == '0' else -1


def copy_mod(mod_root, workspace):
    destination = Path(workspace) / 'mod'
    shutil.copytree(mod_root, destination)
    return destination


def inject_fake_write(copy_root):
    """往 source_formb.lua 插一行假写调用：它在默认构建里会被打包、但不在写面登记里。"""
    path = copy_root / 'src' / 'game' / 'source_formb.lua'
    text = path.read_text(encoding='utf-8')
    if FAKE_WRITE_ANCHOR not in text:
        raise RuntimeError('假写依赖注入锚点缺失：' + str(path))
    path.write_bytes(text.replace(FAKE_WRITE_ANCHOR,
                                  FAKE_WRITE_ANCHOR + '\n' + FAKE_WRITE_LINE, 1).encode('utf-8'))


def narrow_write_modules(copy_root):
    """把副本里 build.py 的 WRITE_PATH_MODULES 收窄成只剩 instant.lua。"""
    path = copy_root / 'build.py'
    text = path.read_text(encoding='utf-8')
    anchor = "WRITE_PATH_MODULES = ('game/instant', 'game/vendor/bingus_write')"
    if anchor not in text:
        raise RuntimeError('写面登记收窄锚点缺失：' + str(path))
    path.write_bytes(text.replace(anchor, "WRITE_PATH_MODULES = ('game/instant',)", 1).encode('utf-8'))


class Gate:
    def __init__(self):
        self.failures = []

    def check(self, condition, message):
        if condition:
            print('ok: ' + message)
        else:
            print('FAIL: ' + message)
            self.failures.append(message)

    def said(self, text, needle):
        return needle in text


def main():
    gate = Gate()
    given = os.environ.get('MOD_SRC')
    mod_root = Path(given).resolve() if given else DEFAULT_MOD
    if not mod_root.is_dir():
        print('FAIL: MOD_SRC 指向的源码树不存在：' + str(mod_root))
        print('failures=1')
        return 1
    src_root = mod_root / 'src'
    if not src_root.is_dir():
        print('FAIL: 源码树里没有 src/：' + str(src_root))
        print('failures=1')
        return 1
    print('gate: MOD-WRITE 源码树=%s' % mod_root)

    build = load_build(mod_root)
    gate.check(tuple(build.WRITE_PATH_MODULES) == WRITE_PATH_MODULES,
               '写面登记与规格口径一致（默认产物不得含任何写路径文件）')
    gate.check(tuple(build.MODULE_ORDER) + tuple(build.AUTHORIZE_ONLY_MODULES) == tuple(build.AUTHORIZED_MODULE_ORDER),
               '授权模块序＝默认模块序 ＋ 写路径模块')
    for key in WRITE_PATH_MODULES:
        gate.check(key not in tuple(build.MODULE_ORDER), '写路径文件 %s 不进默认模块序' % key)
    gate.check('game/wiring.lua' not in tuple(build.MODULE_ORDER)
               and 'game/wiring' not in tuple(build.MODULE_ORDER),
               '授权接线模块不进默认模块序（A-2 的唯一差异轴＝模块集）')
    gate.check('game/logsink.lua' not in tuple(build.MODULE_ORDER)
               and 'game/logsink.lua' in tuple(build.AUTHORIZE_ONLY_MODULES),
               '日志端点件不进默认模块序、只在授权模块序（授权构型落盘由它在场决定）')

    # ① 整棵源树扫描：写调用只许出现在写面登记的文件里
    sites = scan_write_sites(src_root)
    stray = [site for site in sites if site.split('.lua:')[0] not in WRITE_PATH_MODULES]
    gate.check(not stray, '默认源树里没有未登记的写调用（命中：%s）' % (', '.join(stray) if stray else '无'))
    registered = [site for site in sites if site.split('.lua:')[0] in WRITE_PATH_MODULES]
    gate.check(bool(registered), '写面登记文件里确实存在写调用（写能力没被误删）')

    workspace = tempfile.mkdtemp(prefix='w6_write_gate_')
    try:
        # ② 对照组：干净副本默认构建必须绿
        clean = copy_mod(mod_root, Path(workspace) / 'clean')
        code, out, err = run_build(clean, ['--output', Path(workspace) / 'clean.zip'])
        gate.check(code == 0, '干净副本默认构建成功（退出码 %d）' % code)
        gate.check(gate.said(out, 'composed entry:'), '干净副本打印组装读数')

        # ②b 假写依赖：默认构建必须硬失败，且报出注入点，不产出任何文件
        injected = copy_mod(mod_root, Path(workspace) / 'injected')
        inject_fake_write(injected)
        target = Path(workspace) / 'injected.zip'
        code, out, err = run_build(injected, ['--output', target])
        gate.check(code != 0, '注入假写依赖后默认构建硬失败（退出码 %d）' % code)
        gate.check(gate.said(err, 'write call in default build source'),
                   '失败原因指向源码级写调用（stderr：%s）' % err.strip().splitlines()[:1])
        gate.check(not target.exists(), '硬失败时不产出任何文件')

        # ②c 收窄写面登记后仍必须红：证明判据不是「instant.lua 缺席」
        narrowed = copy_mod(mod_root, Path(workspace) / 'narrowed')
        narrow_write_modules(narrowed)
        inject_fake_write(narrowed)
        code, out, err = run_build(narrowed, ['--output', Path(workspace) / 'narrowed.zip'])
        gate.check(code != 0, '写面登记只剩 instant.lua 时，注入副本仍然硬失败（退出码 %d）' % code)
        gate.check(gate.said(err, 'write call in default build source'),
                   '收窄后失败原因仍是源码级写调用')

        # ③ 物理隔离：授权产物绝不进 releases/
        isolation = copy_mod(mod_root, Path(workspace) / 'isolation')
        escaped = isolation.parent / 'releases' / ('Active-Reload-v%s-write.zip' % build.MOD_VERSION)
        code, out, err = run_build(isolation, ['--authorize-write', '--output', escaped])
        gate.check(code != 0, '授权构建写进 releases/ 硬失败（退出码 %d）' % code)
        gate.check(gate.said(err, 'authorized build must not write into releases/'),
                   '失败原因指向产物隔离（stderr：%s）' % err.strip().splitlines()[:1])
        gate.check(not escaped.exists(), '隔离硬失败时不产出任何文件')
        code, out, err = run_build(isolation, ['--output', isolation.parent / 'authorized' / 'default.zip'])
        gate.check(code != 0, '默认构建写进 authorized/ 同样硬失败（退出码 %d）' % code)

        # ③b 授权模式自洽：不指定路径时落到副本的 authorized/，并写进副本的登记表
        code, out, err = run_build(isolation, ['--authorize-write'])
        gate.check(code == 0, '授权构建在副本里成功（退出码 %d）' % code)
        landed = isolation.parent / 'authorized' / ('Active-Reload-v%s-write.zip' % build.MOD_VERSION)
        gate.check(landed.is_file(), '授权产物落在 authorized/（%s）' % landed.name)
        gate.check(gate.said(out, 'registered:'), '授权构建打印登记行')

        # ④ 写批次上限与回滚记账：由 L1 的 instant 用例见证（含空转检查：用例真的跑了）
        code, output = run_cases(mod_root, ('test_instant.lua',))
        gate.check(code == 0 and 'FAIL: ' not in output, 'instant 用例全绿（写批次上限与回滚记账由它见证，exit %d）' % code)
        passed = case_passed(output)
        gate.check(passed >= 40, 'instant 用例真的跑了（passed=%d，需 ≥40，防静默空跑）' % passed)

        # ⑤ 写路径接线、容量采集与写面证据行（行为面）：由 L1 的 wiring 用例见证
        code, output = run_cases(mod_root, ('test_wiring.lua',))
        gate.check(code == 0 and 'FAIL: ' not in output,
                   'wiring 用例全绿（授权装配接线、容量采集与写面证据行由它见证，exit %d）' % code)
        wiring_passed = case_passed(output)
        gate.check(wiring_passed >= 30, 'wiring 用例真的跑了（passed=%d，需 ≥30，防静默空跑）' % wiring_passed)

        # ⑥ 日志文件端点（行为面）：由 L1 的 logsink 用例见证
        code, output = run_cases(mod_root, ('test_logsink.lua',))
        gate.check(code == 0 and 'FAIL: ' not in output,
                   'logsink 用例全绿（端点装配、时序字段、行数上界与失败回退由它见证，exit %d）' % code)
        sink_passed = case_passed(output)
        gate.check(sink_passed >= 30, 'logsink 用例真的跑了（passed=%d，需 ≥30，防静默空跑）' % sink_passed)
    finally:
        shutil.rmtree(workspace, ignore_errors=True)

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
