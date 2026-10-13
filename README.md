# Active Reload

**HELLDIVERS 2 的时机型主动换弹 mod / A timing-based active-reload mod for HELLDIVERS 2.**

> 项目状态：**已搁置**，停在 `v0.3.15-dev` 完成态。功能完整可用，源码与自测齐全。
> Status: **shelved**, frozen at `v0.3.15-dev`. Feature-complete and fully self-tested.

换弹过程中，屏幕上会出现一条进度条与游标；在游标进入命中区时按下 **R**，换弹立即完成、弹匣补满。按错时机则进度条转为灰红走完，本轮内再按无效。

While a reload is in progress, a progress bar with a moving marker is drawn on screen. Press **R** while the marker is inside the hit zone to finish the reload instantly and refill the magazine. Miss the window and the bar turns grey-red for the rest of that reload, and pressing R again has no effect.

---

## 功能 / Features

- 每帧进度条绘制，游标随换弹进度推进。 Per-frame progress bar; the marker follows reload progress.
- 命中区与整条长度、厚度、位置均可在游戏内调整。 Hit zone, bar length, thickness and position are adjustable in-game.
- 按错惩罚：进度条转灰红，本轮按键无效。 Miss penalty: bar turns grey-red and the key is ignored for the rest of the reload.
- 两个构建：**只读包**（仅读取与记录，零写入）与 **写入包**（启用主动换弹写入）。
  Two builds: a **read-only build** (reads and logs only, performs no writes) and a **write-enabled build**.
- 菜单文本支持中文／跟随游戏语言。 Menu text follows the game's selected language (Chinese available).

## 前置 / Requirements

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader) | v19 | **必需**。放入 Arsenal 列表**最底部**。 |
| [Mod Options Menu](https://github.com/CowboyBingus/ModOptionsMenu) | v1.2 | 可选。用于游戏内调整进度条参数与菜单语言。 |

两个依赖均为 0BSD 许可。版本需与游戏 Steam build **25480438** 匹配；游戏更新后请改用生态官方的新 release（详见 `vendor/VENDOR.md`）。

Both dependencies are 0BSD-licensed. The versions above target game Steam build **25480438**; after a game update, switch to the current official releases (see `vendor/VENDOR.md`).

## 安装 / Installation

1. 将 `releases/` 下的 zip 通过 Arsenal 导入（只读包或写入包，二选一）。
2. 勾选启用 → 点击 Deploy。
3. 启动游戏后确认该 mod 出现在 ModBindings 列表中。

1. Import a zip from `releases/` through Arsenal (read-only **or** write-enabled, not both).
2. Enable it, then click Deploy.
3. After launching the game, confirm the mod appears in the ModBindings list.

## 使用 / Usage

1. 游戏内装备支持的武器，**先自然换弹一次**（每局首次换弹前主动换弹不可用，见「已知限制」）。
2. 换弹开始后游标从左向右移动；进入白色命中区时按 **R**。
3. 命中即换弹完成、弹匣补满；按错则本轮失效。
4. 参数与语言：游戏内 **Mod Options → Active Reload**。

1. Equip a supported weapon and **perform one natural reload first** (see Known limitations).
2. When a reload starts, the marker sweeps left to right; press **R** inside the white hit zone.
3. A hit completes the reload and refills the magazine; a miss wastes that reload.
4. Settings and language: in-game **Mod Options → Active Reload**.

## 配置项 / Configuration

| 选项 | 默认 | 范围 | 说明 |
| --- | --- | --- | --- |
| 进度条长度 / Bar length | 25% | 10–50% | 相对屏幕宽度。 |
| 进度条厚度 / Bar thickness | 1.0% | 0.5–2.0% | 相对屏幕宽度。 |
| 准星下方偏移 / Bar offset | 10% | 5–20% | 相对屏幕宽度的垂直偏移。 |
| 语言 / Language | 跟随游戏 | 跟随游戏／中文／English | 菜单文本语言。 |

## 已知限制 / Known limitations

1. **每局首次换弹无效。** 开局后需先自然换弹一次，写链路才进入可用状态。
2. **成功换弹会消耗 1 匣备弹。** 主动换弹补满弹匣时，备弹按一匣扣除。
3. **比自然换弹少 1 发膛内弹。** 主动换弹写入后的膛内弹量低于游戏自然换弹的结果。
4. **备弹仅剩最后一匣时可能被游戏覆盖。** 极端时序下写入会被游戏自身的完成逻辑覆盖，最坏相差 1 发。
5. 当前仅验证了**爆裂铳（弹匣 5 发）**；其他武器未纳入验证范围。
6. **写入包用于联机环境的风险由使用者自担。** 本模组直接改动游戏内存，是否在联机环境使用请自行评估。

1. **The first reload of a match does nothing.** Perform one natural reload to prime the write path.
2. **A successful reload consumes one magazine of reserve ammo.**
3. **One fewer chambered round than a natural reload.**
4. **With a single reserve magazine left, the write can be overwritten by the game**, off by at most one round.
5. Only **爆裂铳 (5-round magazine)** has been verified; no other weapon is in scope.
6. **Using the write-enabled package in multiplayer is at your own risk.** The mod writes to game memory directly.

## 构建与自测 / Building and testing

需要 Python 3.10 及以上。 Requires Python 3.10+.

```bash
# 生成发布包 / build a package (default, or write-enabled with --authorize-write)
python mod/build.py --output releases/Active-Reload-v0.3.15-dev.zip
python mod/build.py --authorize-write --output authorized/Active-Reload-v0.3.15-dev-write.zip

# 校验已产出的 ZIP / verify a produced ZIP
python mod/build.py --verify releases/Active-Reload-v0.3.15-dev.zip

# 静态检查与断言 / static gates
python mod/tests/compile_check.py
python mod/tests/entry_check.py
python mod/tests/memory_check.py
python mod/tests/write_gate_check.py
python mod/tests/mutant_check.py
```

静态门需要一份 **Lua 5.1 解释器动态库**：默认取仓库根的 `game-bin/lua51.dll`（把游戏安装目录下的 `lua51.dll` 复制过去即可），也可用 `--lua <路径>` 或环境变量 `ACTIVERELOAD_LUA` 指定。本仓库不附带该文件。

The static gates need a **Lua 5.1 shared library**. By default they look for `game-bin/lua51.dll` in the repository root (copy the game's `lua51.dll` there); alternatively point them with `--lua <path>` or the `ACTIVERELOAD_LUA` environment variable. This repository does not ship it.

Lua 侧用例由 `mod/tests/run_all.lua` 汇总，经 `compile_check.py --run` 驱动执行。
Lua test cases are aggregated by `mod/tests/run_all.lua` and driven by `compile_check.py --run`.

## 目录结构 / Repository layout

```
mod/
  build.py          构建脚本：拼装入口资源、产出发布包并校验指纹
  src/              产品源码（Lua）
    core/           纯算法层：状态机、时间轴、命中区
    game/           游戏侧接线：读取、写入、驱动、日志
    ui/             进度条绘制
  tests/            静态门与 Lua 用例
releases/           发布包
vendor/VENDOR.md    第三方依赖说明
```

## 第三方 / Third-party

本仓库不包含 Bingus Shared Loader 与 Mod Options Menu 的源码；两者均为 0BSD 许可，来源与校验值见 `vendor/VENDOR.md`。
This repository does not vendor the sources of Bingus Shared Loader or Mod Options Menu; both are 0BSD-licensed. See `vendor/VENDOR.md` for provenance and checksums.

## 许可 / License

MIT，全文见 [`LICENSE`](LICENSE)。
The project is MIT-licensed; see [`LICENSE`](LICENSE).

`mod/src/game/vendor/` 下的三个文件是上游的 **0BSD** 副本，保留其原有许可（见 `vendor/VENDOR.md`）。
The three files under `mod/src/game/vendor/` are upstream **0BSD** copies and keep their original license (see `vendor/VENDOR.md`).

## 作者 / Author

阿巴阿巴

## 致谢 / Credits

- CowboyBingus — Bingus Shared Loader, Bingus Shared Runtime, Mod Options Menu
