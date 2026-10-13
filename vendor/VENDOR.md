# vendor — 第三方依赖 / Third-party dependencies

本 mod 依赖以下两个第三方 mod，均出自 **CowboyBingus**，均为 **0BSD** 许可（可自由使用、修改、再分发）。
This mod depends on two third-party mods by **CowboyBingus**, both **0BSD**-licensed.

| 依赖 | 版本 | 来源 | SHA256 |
| --- | --- | --- | --- |
| Bingus Shared Loader | v19 | `github.com/CowboyBingus/BingusSharedLoader/releases/tag/v19` | `d96ad112f74bd0e360dca9b41abade5377e8cb37ed784ffc8cf07ccc1d9d1ca8` |
| Mod Options Menu | v1.2 | `github.com/CowboyBingus/ModOptionsMenu/releases/tag/v1.2` | `a977d84e7f8fda62c587b5b5af2012aab3fa792e31945a9c8d5f458bfd453e13` |

- **Bingus Shared Loader** 是硬依赖：Arsenal 导入后置于列表**最底部**。
- **Mod Options Menu** 是软依赖：缺席时使用内置默认值。
- 本仓库不附带这两个 zip，请从上游 release 页下载；上方 SHA256 为已验证值。
- 版本需与游戏 Steam build **25480438** 匹配；游戏更新后以生态官方新 release 为准。

This repository does not bundle the two zips; download them from the upstream release
pages. The versions above target game Steam build **25480438**; after a game update,
use the current official releases.

## 仓库内嵌的第三方源码 / Vendored third-party sources

`mod/src/game/vendor/` 下三个文件逐字节取自上游，构建期会重算哈希校验（见 `mod/build.py` 的 `VENDOR_TABLE`）：
The three files under `mod/src/game/vendor/` are byte-for-byte upstream copies and are
hash-verified at build time (see `VENDOR_TABLE` in `mod/build.py`):

| 文件 | 上游 |
| --- | --- |
| `bingus_runtime.lua` | Bingus Shared Runtime — `c4450f555f697e583916d18f876412ca96f6963eb1bf4cdad451ebb906c2f988` |
| `bingus_memory.lua` | Bingus Shared Runtime — `3973924b1c009cc4e6c863a4eaf87f166899a16ddcb579c3d77ab5465172b416` |
| `bingus_write.lua` | Bingus Shared Loader 写入原语 — `9a0a217811d109418faebb2af8804bfb8301b0eeeb1e6b5bc020fdacbd596160` |
