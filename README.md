# OprX Router

基于 OpenWrt 官方 ImageBuilder 的自定义固件构建工具。**3~5 分钟**出镜像，**保留仓库**供刷机后继续 `apk add`。

## 快速开始

1. Fork 本仓库
2. Actions → "Build" → Run workflow（留空 = 构建全部设备）
3. 等 3~5 分钟 → Releases 下载 `.img.gz` 和 `.sha256`

## 配置（改 3 个文件即可）

| 文件 | 改什么 |
| :--- | :--- |
| `config/build.conf` | 版本、主机名、LAN IP、密码、仓库开关 |
| `config/common-pkgs.list` | 预装包清单（只写包名，apk 自动找源） |
| `config/targets/*.conf` | 每个设备的 target/profile/驱动 |

## 支持设备

x86_64、友善 NanoPi R2S/R2C/R3S/R4S。加新设备：复制一个 target conf + 在 `config/targets.json` 加一行。

## 预装 vs 仓库

- **预装**：`config/common-pkgs.list` 里的包全部打进镜像，开箱即用
- **仓库**：`config/build.conf` 的 `REPOS` 里启用的源，构建时写两处（给 make image + 给刷机后）
- **刷机后**：`apk add 任何包` 直接成功（NJU 镜像 + 官方源 + 第三方源都在）

## 登录

- Web: `http://192.168.8.1`
- 用户: `root`
- 密码: `password`

## 本地构建

```bash
sudo apt-get install zstd wget jq qemu-utils make
./build.sh                          # 默认 x86_64
ARCH_OVERRIDE=r2s ./build.sh        # 构建 R2S