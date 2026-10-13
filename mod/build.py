"""Active Reload 构建脚本：把 src/ 下的多个 Lua 源文件组装成单个入口资源，产出管理工具可导入的 ZIP。

用法（在任意目录下执行均可，路径以本脚本所在目录为基准）：
    python -B mod/build.py                        生成 releases/Active-Reload-v<版本>.zip
    python -B mod/build.py --output <文件.zip>    指定输出位置；--emit-entry <文件.lua> 只写出入口源码
    python -B mod/build.py --verify <文件.zip>    校验已产出的 ZIP；--authorize-write 授权构建

产物结构：明文入口资源（首行为资源名声明）+ 单资源 patch archive + 管理器清单 + 两个空 sidecar；同名资源在
管理器部署时按列表顺序重编号，归档字节逐字节保留。两套产物物理隔离：默认产物只进 releases/，授权产物只进
authorized/（后缀 -write，写进 releases/ 直接硬失败），且默认产物不得含任何写路径文件（模块清单 + 源码级写调用
扫描双重把关）；每次构建向 HASH_LEDGER 追加一行哈希登记，从不重写历史行。
"""

import argparse
import datetime
import hashlib
import json
import re
import struct
import sys
import zipfile
from pathlib import Path

MOD_ROOT = Path(__file__).resolve().parent
SOURCE_ROOT = MOD_ROOT / 'src'
REPO_ROOT = MOD_ROOT.parent
DEFAULT_OUTPUT_DIR = REPO_ROOT / 'releases'
AUTHORIZED_OUTPUT_DIR = REPO_ROOT / 'authorized'
AUTHORIZED_SUFFIX = '-write'
MODE_DEFAULT = 'default'
MODE_AUTHORIZED = 'authorized'
HASH_LEDGER = REPO_ROOT / 'build-hashes.tsv'
LEDGER_COLUMNS = 'timestamp\tmode\toutput_path\tzip_sha256\tpayload_sha256\tentry_sha256\twrite_modules\tmodule_manifest'
# 写路径文件：默认产物里一个都不许有，判据是「不存在任何写路径文件」而不是「instant.lua 缺席」。
WRITE_PATH_MODULES = ('game/instant', 'game/vendor/bingus_write')
WRITE_CALL_PATTERN = re.compile(r'\bwrite_batch\s*\(')
# vendored 三件的放置路径、上游来源与逐字节哈希；构建期逐项重算比对，不符即硬失败。
# 上游来源为上游仓库内的相对路径（仓库地址、版本与许可见 vendor/VENDOR.md）。
VENDOR_TABLE = {
    'game/vendor/bingus_runtime': ('BingusSharedRuntime/runtime/bingus_runtime.lua',
                                   'c4450f555f697e583916d18f876412ca96f6963eb1bf4cdad451ebb906c2f988'),
    'game/vendor/bingus_memory': ('BingusSharedRuntime/runtime/bingus_memory.lua',
                                  '3973924b1c009cc4e6c863a4eaf87f166899a16ddcb579c3d77ab5465172b416'),
    'game/vendor/bingus_write': ('BingusSharedLoader/bingus_write.lua',
                                 '9a0a217811d109418faebb2af8804bfb8301b0eeeb1e6b5bc020fdacbd596160'),
}

RESOURCE_NAME = 'mods/hd2mod/active_reload'
DISPLAY_NAME = 'Active Reload'
MOD_VERSION = '0.3.15-dev'
GUID = '8eb46631-bf94-4cda-93ff-d66b92f4c1a1'
DESCRIPTION = ('Requires Bingus Shared Loader (API 1). '
               'Mod Options Menu is optional; settings fall back to defaults without it.')

ENTRY_FILE = 'active_reload.lua'
METADATA_KEY = 'build'
MODULE_ORDER = (
    'config.lua', 'log.lua', 'options.lua',
    'core/zone.lua', 'core/timeline.lua', 'core/state.lua',
    'game/reload.lua', 'game/access.lua', 'game/input.lua', 'game/time.lua',
    'game/vendor/bingus_runtime.lua', 'game/driver.lua',
    'game/vendor/bingus_memory.lua',
    'game/memory.lua', 'game/source_formb.lua', 'ui/bar.lua',
)
# 只许进授权构建的模块：写路径文件（instant 的写批次 + vendored 写面）与日志文件端点件。
AUTHORIZE_ONLY_MODULES = ('game/instant.lua', 'game/wiring.lua',
                          'game/logsink.lua', 'game/vendor/bingus_write.lua')
AUTHORIZED_MODULE_ORDER = MODULE_ORDER + AUTHORIZE_ONLY_MODULES
MODULE_LINE_LIMIT = 300
# 单件行预算覆盖：定向解冻件可单独放宽（其余模块一律 MODULE_LINE_LIMIT）。
MODULE_LINE_LIMIT_OVERRIDE = {'game/access.lua': 310, 'game/wiring.lua': 395, 'ui/bar.lua': 330}

NAME_PATTERN = re.compile(r'mods/[A-Za-z0-9_]+/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*')
RESERVED_NAMES = ('mods/codex/loader',)
DECLARATION_LIMIT = 256

ARCHIVE_NAME = '9ba626afa44a3aa3.patch_0'
ARCHIVE_MAGIC = 0xF0000011
RESOURCE_TYPE = 0xA14E8DFA2CD117E2
ARCHIVE_ALIGN = 16
ENVELOPE_VERSION = 2
HEADER_FORMAT = '<III20sQQ24s'
TYPE_FORMAT = '<IIQIIII'
ENTRY_FORMAT = '<7Q6I'
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
TYPE_SIZE = struct.calcsize(TYPE_FORMAT)
ENTRY_SIZE = struct.calcsize(ENTRY_FORMAT)
ENTRY_BASE = HEADER_SIZE + TYPE_SIZE
FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
FILE_MODE = 0o100644 << 16

class BuildError(Exception):
    """源文件或产物的契约检查未通过。"""

def source_relative_files(modules=MODULE_ORDER):
    """按固定顺序返回入口与各模块的源文件相对路径。"""
    return tuple(modules) + (ENTRY_FILE,)

def read_source(relative):
    """读取一个源文件并执行编码与规模检查，返回文本。"""
    path = SOURCE_ROOT / relative
    if not path.is_file():
        raise BuildError('missing source file: ' + str(path))
    data = path.read_bytes()
    if data.startswith(b'\xef\xbb\xbf'):
        raise BuildError('source must not start with a BOM: ' + relative)
    if b'\r' in data:
        raise BuildError('source must use LF line endings: ' + relative)
    if b'\0' in data:
        raise BuildError('source must not contain NUL bytes: ' + relative)
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as error:
        raise BuildError('source must be UTF-8: ' + relative + ' (' + str(error) + ')')
    lines = text.count('\n')
    limit = MODULE_LINE_LIMIT_OVERRIDE.get(relative, MODULE_LINE_LIMIT)
    if lines > limit:
        raise BuildError('source exceeds %d lines: %s (%d)' % (limit, relative, lines))
    if not text.endswith('\n'):
        raise BuildError('source must end with a newline: ' + relative)
    return text

def declaration_line(name=RESOURCE_NAME):
    return '-- HD2-Addon: ' + name + '\n'

def validate_resource_name(name):
    if not NAME_PATTERN.fullmatch(name):
        raise BuildError('use mods/<author>/<entry> with letters, digits and underscores: ' + name)
    if name in RESERVED_NAMES:
        raise BuildError('resource name is reserved: ' + name)

def validate_entry(text, name=RESOURCE_NAME):
    """入口源码的契约检查：明文、无 BOM、首行声明、声明长度上限。"""
    validate_resource_name(name)
    line = declaration_line(name)
    if not text.startswith(line):
        raise BuildError('entry must start with: ' + line.strip())
    if len(line.encode('utf-8')) > DECLARATION_LIMIT:
        raise BuildError('entry declaration must fit within %d bytes' % DECLARATION_LIMIT)
    data = text.encode('utf-8')
    if data.startswith(b'\xef\xbb\xbf') or b'\0' in data:
        raise BuildError('entry must be plaintext UTF-8 without a BOM')
    if b'\x1b' in data:
        raise BuildError('entry must stay plaintext: found a bytecode escape byte')

def module_key(relative):
    if not relative.endswith('.lua'):
        raise BuildError('module source must end with .lua: ' + relative)
    return relative[:-len('.lua')]

def metadata_source():
    return ('    return {\n'
            "        resource = '%s',\n" % RESOURCE_NAME +
            "        version = '%s',\n" % MOD_VERSION +
            "        guid = '%s',\n" % GUID +
            '    }\n')

def compose_entry(modules=MODULE_ORDER):
    """把模块与入口组装成单个明文入口资源。"""
    entry_text = read_source(ENTRY_FILE)
    line = declaration_line()
    first, separator, remainder = entry_text.partition('\n')
    if first.rstrip('\r') == line.rstrip('\n'):
        entry_text = remainder
    elif first.startswith('-- HD2-Addon:'):
        raise BuildError('entry declaration must match ' + RESOURCE_NAME)
    parts = [
        line,
        '-- 本文件由构建脚本生成：以下模块按固定顺序注入同一个入口资源；改动请落在 src/ 下的源文件。\n',
        '\n',
        'local __active_reload_modules = {}\n',
        'local function __active_reload_define(name, body)\n',
        '    __active_reload_modules[name] = body()\n',
        'end\n',
    ]
    for relative in modules:
        parts.append("\n__active_reload_define('%s', function()\n" % module_key(relative))
        parts.append(read_source(relative))
        parts.append('end)\n')
    parts.append("\n__active_reload_define('%s', function()\n" % METADATA_KEY)
    parts.append(metadata_source())
    parts.append('end)\n')
    parts.append('\nlocal modules = __active_reload_modules\n')
    parts.append(entry_text)
    text = ''.join(parts)
    validate_entry(text)
    return text

def murmur_hash64a(data):
    """种子为 0 的 MurmurHash64A，与生态打包脚本的实现一致。"""
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)

def resource_hash(name=RESOURCE_NAME):
    return murmur_hash64a(name.encode('utf-8'))

def make_archive(resources):
    """把 {资源键: 资源字节} 编码成 patch archive；字节布局与生态归档脚本逐字节一致。"""
    if not resources:
        raise BuildError('an archive needs at least one resource')
    count = len(resources)
    offset = (ENTRY_BASE + ENTRY_SIZE * count + ARCHIVE_ALIGN - 1) & ~(ARCHIVE_ALIGN - 1)
    entries, body = bytearray(), bytearray(offset)
    for index, (key, resource) in enumerate(sorted(resources.items())):
        entries += struct.pack(ENTRY_FORMAT, key, RESOURCE_TYPE, offset, 0, 0, 0, 0,
                               len(resource), 0, 0, 16, 16, index)
        body += resource
        body += b'\0' * (-len(body) % ARCHIVE_ALIGN)
        offset = len(body)
    header = struct.pack(HEADER_FORMAT, ARCHIVE_MAGIC, 1, count, b'', offset, 0, b'')
    types = struct.pack(TYPE_FORMAT, 0, 0, RESOURCE_TYPE, count, 0, 16, 16)
    body[:ENTRY_BASE + len(entries)] = header + types + entries
    return bytes(body)

def read_resource(data, key):
    magic, types, count = struct.unpack_from('<III', data)
    if magic != ARCHIVE_MAGIC:
        raise BuildError('not a patch archive')
    for index in range(count):
        row = struct.unpack_from(ENTRY_FORMAT, data, HEADER_SIZE + types * TYPE_SIZE + index * ENTRY_SIZE)
        if row[0] == key:
            if row[2] + row[7] > len(data):
                raise BuildError('truncated patch archive')
            return data[row[2]:row[2] + row[7]]
    return None

def envelope(text):
    body = text.encode('utf-8')
    return struct.pack('<II', len(body), ENVELOPE_VERSION) + body

def manifest():
    return {
        'Version': 1,
        'Guid': GUID,
        'Name': DISPLAY_NAME,
        'Description': DESCRIPTION,
        'Options': [{'Name': DISPLAY_NAME, 'Description': DESCRIPTION, 'Include': ['Addon']}],
    }

def package_files(entry_text):
    archive = make_archive({resource_hash(): envelope(entry_text)})
    return {
        'manifest.json': (json.dumps(manifest(), indent=2) + '\n').encode('utf-8'),
        'Addon/' + ARCHIVE_NAME: archive,
        'Addon/' + ARCHIVE_NAME + '.stream': b'',
        'Addon/' + ARCHIVE_NAME + '.gpu_resources': b'',
    }

def write_package(entry_text, output):
    """写出 ZIP：固定时间戳与文件顺序，保证同源输入产出逐字节相同的容器。"""
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as package:
        for name, content in sorted(package_files(entry_text).items()):
            info = zipfile.ZipInfo(name, date_time=FIXED_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = FILE_MODE
            package.writestr(info, content)
    return output

def verify_package(path):
    """等效自证：清单、单资源归档、空 sidecar、资源键、明文声明与封装版本逐项核对。"""
    path = Path(path)
    if not path.is_file():
        raise BuildError('package not found: ' + str(path))
    findings = []
    with zipfile.ZipFile(path) as package:
        names = package.namelist()
        expected = ['Addon/' + ARCHIVE_NAME,
                    'Addon/' + ARCHIVE_NAME + '.gpu_resources',
                    'Addon/' + ARCHIVE_NAME + '.stream',
                    'manifest.json']
        if sorted(names) != expected:
            raise BuildError('unexpected package layout: ' + ', '.join(sorted(names)))
        data = json.loads(package.read('manifest.json'))
        if data.get('Version') != 1:
            raise BuildError('manifest Version must be 1')
        options = data.get('Options') or []
        if len(options) != 1 or options[0].get('Include') != ['Addon']:
            raise BuildError('manifest must declare exactly one Addon option')
        if data.get('Name') != DISPLAY_NAME or data.get('Guid') != GUID:
            raise BuildError('manifest identity does not match the build constants')
        findings.append('manifest: Guid %s, Include ["Addon"]' % data['Guid'])
        for suffix in ('.stream', '.gpu_resources'):
            if package.read('Addon/' + ARCHIVE_NAME + suffix) != b'':
                raise BuildError('sidecar must be empty: ' + suffix)
        archive = package.read('Addon/' + ARCHIVE_NAME)
    magic, types, count = struct.unpack_from('<III', archive)
    if magic != ARCHIVE_MAGIC or count != 1:
        raise BuildError('archive header must hold exactly one resource')
    row = struct.unpack_from(ENTRY_FORMAT, archive, HEADER_SIZE + types * TYPE_SIZE)
    if row[0] != resource_hash() or row[1] != RESOURCE_TYPE:
        raise BuildError('archive key or resource type does not match the resource name')
    size, version = struct.unpack_from('<II', archive, row[2])
    if size != row[7] - 8 or version != ENVELOPE_VERSION:
        raise BuildError('envelope length or version is inconsistent')
    body = read_resource(archive, row[0])[8:]
    text = body.decode('utf-8')
    validate_entry(text)
    findings.append('archive: key %016X, %d resource, payload %d bytes'
                    % (row[0], count, len(body)))
    findings.append('entry: declaration on line 1, %d bytes of plaintext Lua' % len(body))
    findings.append('payload sha256: %s' % hashlib.sha256(body).hexdigest())
    return findings

def sha256_of(data):
    return hashlib.sha256(data).hexdigest()

def write_call_sites(modules):
    """逐行扫这些源文本里的写调用，返回「相对路径:行号」；判据不依赖模块清单。"""
    return ['%s:%d' % (relative, number)
            for relative in source_relative_files(modules)
            for number, line in enumerate(read_source(relative).splitlines(), 1)
            if WRITE_CALL_PATTERN.search(line)]

def check_vendor_table():
    """vendored 三件必须逐字节等于登记值：缺失或不符都硬失败（不静默跳过）。"""
    for key, (origin, expected) in sorted(VENDOR_TABLE.items()):
        path = SOURCE_ROOT / (key + '.lua')
        if not path.is_file():
            raise BuildError('missing vendored file: %s (copy byte for byte from %s)' % (path, origin))
        if sha256_of(path.read_bytes()) != expected:
            raise BuildError('vendored file hash mismatch: ' + str(path))

def check_write_surface(mode, modules):
    """默认产物零写路径文件；授权产物必须含全部写路径模块（构建期闸门）。"""
    keys = {module_key(relative) for relative in modules}
    if mode == MODE_DEFAULT:
        leaked = sorted(keys & set(WRITE_PATH_MODULES))
        if leaked:
            raise BuildError('default build must not include write-path modules: ' + ', '.join(leaked))
        sites = write_call_sites(modules)
        if sites:
            raise BuildError('write call in default build source: ' + sites[0])
    else:
        missing = sorted(set(WRITE_PATH_MODULES) - keys)
        if missing:
            raise BuildError('authorized build must include every write-path module: ' + ', '.join(missing))

def resolve_output(mode, output):
    """定出产物路径，并守住两套产物的物理隔离：授权产物绝不进 releases/。"""
    if mode == MODE_AUTHORIZED:  # 授权模式才创建 authorized/；默认模式不创建该目录
        AUTHORIZED_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    if output is None:
        name = ('Active-Reload-v%s%s.zip' % (MOD_VERSION, AUTHORIZED_SUFFIX)
                if mode == MODE_AUTHORIZED else 'Active-Reload-v%s.zip' % MOD_VERSION)
        return AUTHORIZED_OUTPUT_DIR / name if mode == MODE_AUTHORIZED else DEFAULT_OUTPUT_DIR / name
    resolved = Path(output).resolve()
    inside = lambda root: resolved == root.resolve() or root.resolve() in resolved.parents
    if mode == MODE_AUTHORIZED and inside(DEFAULT_OUTPUT_DIR):
        raise BuildError('authorized build must not write into releases/: ' + str(resolved))
    if mode == MODE_DEFAULT and inside(AUTHORIZED_OUTPUT_DIR):
        raise BuildError('default build must not write into authorized/: ' + str(resolved))
    return Path(output)

def register_build(mode, output, zip_hash, payload_hash, entry_hash, modules):
    """把一次构建登记进 TSV（追加式）：输出路径相对仓库根，默认行的 write_modules 必须是空串。"""
    keys = [module_key(relative) for relative in modules]
    manifest = ','.join('%s:%s' % (key, sha256_of(read_source(relative).encode('utf-8'))[:8])
                        for key, relative in zip(keys, modules))
    resolved = Path(output).resolve()
    root = REPO_ROOT.resolve()
    shown = resolved.relative_to(root).as_posix() if resolved.is_relative_to(root) else resolved.as_posix()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    row = '\t'.join((stamp, mode, shown, zip_hash, payload_hash, entry_hash,
                     ','.join(sorted(set(keys) & set(WRITE_PATH_MODULES))), manifest))
    HASH_LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with open(HASH_LEDGER, 'a', encoding='utf-8', newline='\n') as handle:
        if handle.tell() == 0:
            handle.write(LEDGER_COLUMNS + '\n')
        handle.write(row + '\n')

def parse_arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--output', type=Path, help='产物 ZIP 路径，默认 releases/Active-Reload-v<版本>.zip')
    parser.add_argument('--emit-entry', type=Path, help='只写出组装后的入口源码后退出')
    parser.add_argument('--verify', type=Path, help='校验已有 ZIP 后退出')
    parser.add_argument('--authorize-write', action='store_true',
                        help='授权构建：额外纳入 WRITE_PATH_MODULES，产物只进 authorized/')
    return parser.parse_args(argv)

def main(argv=None):
    arguments = parse_arguments(argv)
    try:
        if arguments.verify:
            for finding in verify_package(arguments.verify):
                print('verify: ' + finding)
            print('verify: %s OK' % arguments.verify)
            return 0
        mode = MODE_AUTHORIZED if arguments.authorize_write else MODE_DEFAULT
        modules = AUTHORIZED_MODULE_ORDER if mode == MODE_AUTHORIZED else MODULE_ORDER
        check_vendor_table()
        check_write_surface(mode, modules)
        text = compose_entry(modules)
        body = envelope(text)
        entry_hash = sha256_of(text.encode('utf-8'))
        print('composed entry: %d bytes (sha256 %s)' % (len(text.encode('utf-8')), entry_hash))
        print('archive payload: %d bytes (sha256 %s)' % (len(body), sha256_of(body)))
        if arguments.emit_entry:
            arguments.emit_entry.parent.mkdir(parents=True, exist_ok=True)
            arguments.emit_entry.write_bytes(text.encode('utf-8'))
            print('entry written: %s' % arguments.emit_entry)
            return 0
        output = resolve_output(mode, arguments.output)
        write_package(text, output)
        zip_hash = sha256_of(output.read_bytes())
        print('built: %s (%d bytes, sha256 %s)' % (output, Path(output).stat().st_size, zip_hash))
        register_build(mode, output, zip_hash, sha256_of(body), entry_hash, modules)
        if mode == MODE_AUTHORIZED: print('registered: %s (mode %s)' % (HASH_LEDGER, mode))
        return 0
    except BuildError as error:
        print('build error: ' + str(error), file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())
