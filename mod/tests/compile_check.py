"""在游戏自带的 lua51.dll 上做编译与自测检查。

用法（在任意目录下执行均可，路径以本脚本所在目录为基准）：
    py -3.11 -B mod/tests/compile_check.py                 编译默认与授权的全部源文件、两套组装入口、工程门
    py -3.11 -B mod/tests/compile_check.py --run            追加运行内联自测（run_all.lua + 十件用例）
    py -3.11 -B mod/tests/compile_check.py --package <ZIP>  追加校验产物并编译其中的入口资源

退出码 0 表示全部检查通过，1 表示存在失败项。检查全程只读，只会在显式传入 --package 时读取该 ZIP。
"""

import argparse
import ctypes
import os
import re
import struct
import sys
from pathlib import Path

MOD_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = MOD_ROOT.parent
# Lua 5.1 解释器动态库：默认取游戏自带的 game-bin/lua51.dll（游戏安装目录下的副本），
# 可用 --lua 指定，或用环境变量 ACTIVERELOAD_LUA 覆盖（便于在无游戏文件的机器上跑门）。
DEFAULT_LUA = Path(os.environ.get('ACTIVERELOAD_LUA', str(REPO_ROOT / 'game-bin' / 'lua51.dll')))
RUNNER = Path(__file__).resolve().parent / 'run_all.lua'
CASE_FILES = (
    'test_zone.lua',
    'test_timeline.lua',
    'test_state.lua',
    'test_options.lua',
    'test_reload.lua',
    'test_access.lua',
    'test_memory.lua',
    'test_source_formb.lua',
    'test_readface.lua',
    'test_stateface.lua',
    'test_instant.lua',
    'test_wiring.lua',
    'test_logsink.lua',
    'test_driver.lua',
    'test_entry.lua',
    'test_bar.lua',
)

# 工程门：白名单为空，默认值只许写在 config.lua。
# 豁免两处：config.lua 是默认值唯一合法出处；access.lua 已定向解冻（聚合容错／缺席守卫／头注三处）且仍免魔法数字门；game/vendor/ 是逐字节上游副本。
ENGINEERING_EXEMPT = ('config.lua', 'game/access.lua')
ENGINEERING_VENDOR_PREFIX = 'game/vendor/'
MAGIC_NUMBER = re.compile(r'\b\d{2,}\b')
FRAME_HEADER = 'function system.frame('
BANNED_SOURCE = ('io.write(', 'os.exit(')

sys.path.insert(0, str(MOD_ROOT))
import build  # 与构建脚本共用同一份路径与归档常量

if hasattr(sys.stdout, 'reconfigure'):  # 控制台默认 GBK：用例消息里的非 GBK 字符会崩 print，先统一编码
    sys.stdout.reconfigure(encoding='utf-8')

GLOBALS_INDEX = -10002  # 环境表下标，用于写入全局 __report


class LuaError(Exception):
    """编译或运行 Lua 源码时返回的错误。"""


class Lua:
    """游戏自带 lua51.dll 的最小封装：编译源码、执行文件、捕获汇报。"""

    def __init__(self, library):
        library = Path(library)
        if not library.is_file():
            raise LuaError('找不到 Lua 解释器: ' + str(library))
        if hasattr(os, 'add_dll_directory'):
            os.add_dll_directory(str(library.parent))
        self.reports = []
        self.library = ctypes.CDLL(str(library))
        self.library.luaL_newstate.restype = ctypes.c_void_p
        self.library.luaL_loadbuffer.restype = ctypes.c_int
        self.library.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                                 ctypes.c_size_t, ctypes.c_char_p]
        self.library.lua_pcall.restype = ctypes.c_int
        self.library.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        self.library.lua_tolstring.restype = ctypes.c_char_p
        self.library.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        self.library.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.library.lua_pushcclosure.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
        self.library.lua_setfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
        self.state = self.library.luaL_newstate()
        if not self.state:
            raise LuaError('luaL_newstate 返回空')
        self.library.luaL_openlibs(self.state)
        self.callback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)(self._collect)
        self.library.lua_pushcclosure(self.state, ctypes.cast(self.callback, ctypes.c_void_p), 0)
        self.library.lua_setfield(self.state, GLOBALS_INDEX, b'__report')

    def _collect(self, state):
        text = self.library.lua_tolstring(state, -1, None)
        self.reports.append(text.decode('utf-8', 'replace') if text else '')
        self.library.lua_settop(state, -2)
        return 0

    def _message(self):
        text = self.library.lua_tolstring(self.state, -1, None)
        self.library.lua_settop(self.state, -2)
        return text.decode('utf-8', 'replace') if text else '未知错误'

    def compile(self, name, text):
        """编译一段源码；通过返回 None，失败返回错误文本。"""
        data = text.encode('utf-8')
        if self.library.luaL_loadbuffer(self.state, data, len(data), name.encode('utf-8')) != 0:
            return self._message()
        self.library.lua_settop(self.state, -2)
        return None

    def run_text(self, name, text):
        """执行一段源码并取回它的返回值；失败时返回 (None, 错误文本)。"""
        data = text.encode('utf-8')
        if self.library.luaL_loadbuffer(self.state, data, len(data), name.encode('utf-8')) != 0:
            return None, self._message()
        if self.library.lua_pcall(self.state, 0, 1, 0) != 0:
            return None, self._message()
        value = self.library.lua_tolstring(self.state, -1, None)
        self.library.lua_settop(self.state, -2)
        return value, None


def frame_body(text):
    """取出帧函数（system.frame）的函数体；找不到返回 None。终止行＝同缩进或深一级的裸 end。"""
    lines = text.split('\n')
    for start, line in enumerate(lines):
        if line.strip().startswith(FRAME_HEADER):
            break
    else:
        return None
    base = len(lines[start]) - len(lines[start].lstrip())
    for depth in (base, base + 4):
        for index in range(start + 1, len(lines)):
            line = lines[index]
            if line.strip() == 'end' and len(line) - len(line.lstrip()) == depth:
                return lines[start:index + 1]
    return None


def engineering_findings(children):
    """工程门：魔法数字、帧路径零闭包与零 pcall、日志一律 print。返回失败描述列表。"""
    findings = []
    for relative in children:
        if relative.startswith(ENGINEERING_VENDOR_PREFIX):
            continue
        text = build.read_source(relative)
        if relative not in ENGINEERING_EXEMPT:
            hits = [str(index) for index, line in enumerate(text.split('\n'), 1)
                    if MAGIC_NUMBER.search(line)]
            if hits:
                findings.append('魔法数字 %s 行 %s（默认值只许在 config.lua）'
                                % (relative, ','.join(hits)))
        for token in BANNED_SOURCE:
            if token in text:
                findings.append('禁用调用 %s: %s' % (token, relative))
    body = frame_body(build.read_source(build.ENTRY_FILE))
    if body is None:
        findings.append('找不到帧函数 %s（%s）' % (FRAME_HEADER.strip(), build.ENTRY_FILE))
    else:
        joined = '\n'.join(body[1:])
        if 'function' in joined:
            findings.append('帧路径内新建闭包: %s' % build.ENTRY_FILE)
        if 'pcall' in joined:
            findings.append('帧路径内用 pcall: %s' % build.ENTRY_FILE)
    return findings


def harness(cases=CASE_FILES):
    """拼出自测程序：宿主把源码内联成函数体，交给 run_all.lua 执行。

    Lua 侧因此完全不读文件，路径含非 ASCII 字符时也不会受影响。cases 只挑选要跑的用例文件。
    """
    parts = ['__sources = {}\n']
    # 自测把写路径模块也内联进来（只是定义，不执行写），便于 instant 用例直接取到被测模块。
    for relative in build.MODULE_ORDER + build.AUTHORIZE_ONLY_MODULES:
        parts.append("__sources['%s'] = function()\n" % relative)
        parts.append(build.read_source(relative))
        parts.append('end\n')
    parts.append("__sources['%s'] = function()\n" % build.METADATA_KEY)
    parts.append(build.metadata_source())
    parts.append('end\n')
    parts.append('__entry = function()\n')
    parts.append(build.read_source(build.ENTRY_FILE))
    parts.append('end\n')
    parts.append('__cases = {}\n')
    for index, name in enumerate(cases, 1):
        with open(Path(__file__).resolve().parent / name, encoding='utf-8') as handle:
            text = handle.read()
        parts.append("__cases[%d] = { name = '%s', body = function()\n" % (index, name))
        parts.append(text)
        parts.append('end }\n')
    with open(RUNNER, encoding='utf-8') as handle:
        parts.append(handle.read())
    return ''.join(parts)


def package_entry(path):
    """从产物 ZIP 中取出入口资源的正文（走构建脚本同一套归档解析）。"""
    import zipfile
    with zipfile.ZipFile(path) as package:
        archive = package.read('Addon/' + build.ARCHIVE_NAME)
    magic = struct.unpack_from('<III', archive)[0]
    if magic != build.ARCHIVE_MAGIC:
        raise LuaError('归档头部不是一个资源')
    payload = build.read_resource(archive, build.resource_hash())
    if payload is None:
        raise LuaError('归档资源键与资源名不一致')
    size, version = struct.unpack_from('<II', payload)
    if version != build.ENVELOPE_VERSION or size != len(payload) - 8:
        raise LuaError('封装长度或版本不一致')
    return payload[8:].decode('utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--lua', type=Path, default=DEFAULT_LUA, help='Lua 解释器动态库，默认游戏自带的 lua51.dll')
    parser.add_argument('--package', type=Path, help='追加校验并编译该产物 ZIP 中的入口资源')
    parser.add_argument('--run', action='store_true', help='追加运行 tests/run_all.lua')
    parser.add_argument('--case', action='append', help='配合 --run 只跑指名的用例文件（可重复，便于各件门只跑自己主题）')
    arguments = parser.parse_args(argv)

    cases = CASE_FILES
    if arguments.case:
        unknown = [name for name in arguments.case if name not in CASE_FILES]
        if unknown:
            print('FAIL: 未知用例文件 ' + ', '.join(unknown))
            return 1
        cases = tuple(name for name in CASE_FILES if name in set(arguments.case))

    failures = []
    try:
        lua = Lua(arguments.lua)
    except LuaError as error:
        print('FAIL: ' + str(error))
        return 1

    children = build.source_relative_files()
    children += tuple(relative for relative in build.AUTHORIZE_ONLY_MODULES
                      if relative not in build.MODULE_ORDER)
    for relative in children:
        text = build.read_source(relative)
        error = lua.compile('@' + relative, text)
        if error:
            failures.append(relative + ': ' + error)
            print('FAIL: 编译 ' + relative + ' -> ' + error)
        else:
            print('ok: 编译 ' + relative)

    found = engineering_findings(children)
    for finding in found:
        failures.append('工程门: ' + finding)
        print('FAIL: 工程门 -> ' + finding)
    if not found:
        print('ok: 工程门（除 config.lua 外零魔法数字、帧路径零闭包零 pcall、日志一律 print）')

    for label, modules in (('默认', build.MODULE_ORDER), ('授权', build.AUTHORIZED_MODULE_ORDER)):
        try:
            composed = build.compose_entry(modules)
        except build.BuildError as error:
            failures.append(label + '组装入口: ' + str(error))
            print('FAIL: %s组装入口 -> %s' % (label, error))
        else:
            error = lua.compile('@active_reload.%s.bundle' % label, composed)
            if error:
                failures.append(label + '组装入口: ' + error)
                print('FAIL: 编译%s组装后的入口 -> %s' % (label, error))
            else:
                print('ok: 编译%s组装后的入口（%d 字节）' % (label, len(composed.encode('utf-8'))))

    if arguments.package:
        try:
            for finding in build.verify_package(arguments.package):
                print('ok: 产物 ' + finding)
            text = package_entry(arguments.package)
            error = lua.compile('@' + arguments.package.name, text)
            if error:
                failures.append('产物入口: ' + error)
                print('FAIL: 编译产物中的入口资源 -> ' + error)
            else:
                print('ok: 编译产物中的入口资源（%d 字节）' % len(text.encode('utf-8')))
        except (build.BuildError, LuaError, OSError, KeyError, struct.error) as error:
            failures.append('产物: ' + str(error))
            print('FAIL: 产物检查 -> ' + str(error))

    if arguments.run:
        lua.reports = []
        value, error = lua.run_text('@active_reload.tests', harness(cases))
        for line in lua.reports:
            print('case: ' + line)
        if error:
            failures.append('自测: ' + error)
            print('FAIL: 运行自测 -> ' + error)
        else:
            failed = int(value) if value and value.isdigit() else 0
            if failed:
                failures.append('自测: %d 项断言或用例失败' % failed)
                print('FAIL: 自测报告 %d 项失败' % failed)
            else:
                print('ok: 自测全部通过')

    print('result: %s' % ('通过' if not failures else '失败 %d 项' % len(failures)))
    return 0 if not failures else 1


if __name__ == '__main__':
    sys.exit(main())
