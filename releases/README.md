# releases — 发布包 / Release packages

| 文件 | 说明 |
| --- | --- |
| `Active-Reload-v0.3.15-dev.zip` | **只读包**。仅读取游戏状态并记录日志，不含任何写入路径，零风险。 |
| `Active-Reload-v0.3.15-dev-write.zip` | **写入包**。启用主动换弹写入；见仓库根 README 的「已知限制」。 |

安装方式见仓库根 `README.md`。两个包**不要同时安装**，二选一。

See the repository root `README.md` for installation. Install **only one** of the two.

发行包哈希 / SHA256：

```
只读包  e3d1a000de36c2e3d6745d7d4d24b9e1dd18e5a541fb9cb3376d6a1f18a3e04b
写入包  185581b0bf30262fb46a52c1aa0998b152c64b129bf019d9283ff4ddb24f5604
```

两个包均由 `mod/build.py` 从本仓库源码构建得出，可用 `python mod/build.py --verify <文件.zip>` 复核。
Both packages are built from this repository's sources by `mod/build.py` and can be re-checked
with `python mod/build.py --verify <file.zip>`.
