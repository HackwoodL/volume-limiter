# Volume Limiter

[English](README.md)

![Volume Limiter 系统设置面板截图](docs/screenshots/prefpane-system-settings.png)

Volume Limiter 是一个轻量级 macOS 最大音量限制器。它通过单一的当前用户守护进程监听 Core Audio 输出设备和音量变化，一旦当前输出音量超过你设置的上限，就立即压回上限。CLI 和 GUI 都是瘦客户端，只通过 Unix domain socket 与同一个守护进程通信。

## 功能

- 事件驱动的 Core Audio 监听；默认不轮询。
- 当前用户会话内单一守护进程：`volume-limiterd`。
- CLI：`volume-limit`。
- GUI：集成到 macOS“系统设置”的 ad-hoc 签名 `VolumeLimiter.prefPane`。
- prefPane 可见时自动刷新状态，离开面板后停止刷新。
- 配置由 daemon 统一持有，CLI 和 GUI 天然同步。
- 支持“仅蓝牙输出时生效”模式。
- 支持音量被压回时发送 macOS 通知。
- 不安装内核扩展、不安装虚拟音频驱动、不使用 Developer ID、不做 notarization。

## 安装

发布到 Homebrew tap 后：

```bash
brew install HackwoodL/tap/volume-limiter
brew services start volume-limiter
```

GUI 包发布后：

```bash
brew install --cask HackwoodL/tap/volume-limiter-gui
```

本地手动构建：

```bash
swift build
swift run volume-limiter-tests
scripts/test-cli-daemon.py
scripts/install-prefpane.sh
```

## CLI

```bash
volume-limit set <0-100>
volume-limit get
volume-limit on
volume-limit off
volume-limit status
volume-limit bluetooth-only on
volume-limit bluetooth-only off
volume-limit bluetooth-only status
volume-limit --help
```

如果 daemon 没有运行，CLI 会提示：

```text
volume-limiterd is not running.
Start it with: brew services start volume-limiter
```

## 架构

```text
┌────────────────────────────────────────────────────────────┐
│ volume-limiterd                                             │
│ - Core Audio 事件监听                                       │
│ - 音量封顶策略                                              │
│ - 配置管理                                                  │
│ - Unix domain socket server                                 │
└────────────────────────────────────────────────────────────┘
                              ▲
                              │ /tmp/volume-limiter-$UID.sock
                 ┌────────────┴────────────┐
                 │                         │
┌────────────────────────────┐ ┌────────────────────────────┐
│ volume-limit                │ │ VolumeLimiter.prefPane     │
│ CLI 瘦客户端                │ │ 系统设置 GUI 瘦客户端       │
└────────────────────────────┘ └────────────────────────────┘
```

只有 daemon 会调用 Core Audio 读取或修改系统输出音量。CLI 和 GUI 只通过每个用户独立的 Unix socket 发送 newline-delimited JSON 请求。

## GitHub Release 手动安装

从 GitHub Release 下载：

- `volume-limiter-cli-v0.1.0.zip`：universal `arm64`/`x86_64` 的 `volume-limiterd` 和 `volume-limit`
- `VolumeLimiter-gui-v0.1.0.zip`：`VolumeLimiter.prefPane`
- `SHA256SUMS`

解除 ad-hoc 签名/未 notarize 下载文件的 quarantine：

```bash
xattr -cr VolumeLimiter.prefPane volume-limiterd volume-limit
```

手动安装 prefPane：

```bash
mkdir -p ~/Library/PreferencePanes
cp -R VolumeLimiter.prefPane ~/Library/PreferencePanes/
open ~/Library/PreferencePanes/VolumeLimiter.prefPane
```

本项目有意不购买 Apple Developer Program，不使用 Developer ID，也不做 notarization。因此首次打开时 macOS 可能需要你右键打开、执行 `xattr -cr`，或在系统设置中选择“仍要打开”。

## 卸载

只卸载 GUI：

```bash
brew uninstall --cask volume-limiter-gui
```

卸载 CLI 和 daemon：

```bash
brew services stop volume-limiter
brew uninstall volume-limiter
```

彻底清理：

```bash
brew uninstall --cask volume-limiter-gui || true
brew services stop volume-limiter || true
brew uninstall volume-limiter || true
rm -rf ~/Library/Application\ Support/VolumeLimiter \
       ~/Library/PreferencePanes/VolumeLimiter.prefPane \
       ~/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist
```

## 测试

详见 [`docs/TESTING.md`](docs/TESTING.md)。当前已经覆盖 Core 逻辑测试、通知触发测试、IPC 协议测试、CLI 解析/输出测试、Unix socket 冲突测试、真实 daemon + CLI smoke、prefPane 构建/签名/加载、系统设置截图、键盘音量键延迟、蓝牙重连、Type-C 有线耳机、重启自启和基础资源采样。

仍需后续条件满足后验证：HDMI/AirPlay/聚合设备/不支持系统音量控制设备，以及发布真实 GitHub Release/Homebrew tap 后使用正式 URL/SHA 的安装/卸载流程。

## prefPane 状态说明

`NSPreferencePane` 已被 Apple 标记为 deprecated。Volume Limiter v1 仍优先使用它，因为它能在当前 macOS 上提供最接近“系统设置”的集成体验。如果未来 macOS 移除或进一步限制第三方 prefPane，fallback 方案是 SwiftUI 菜单栏 App，但仍保持同一个 daemon + IPC 瘦客户端架构。

## Roadmap

- v0.1.x：完成发布打包、tap 发布和剩余硬件验证。
- v1.0：稳定 CLI + prefPane 分发。
- v2：研究驱动层硬拦截，例如 Core Audio HAL 虚拟设备。v1 明确不安装驱动、kext 或虚拟音频设备。

## 致谢

架构参考了 `batt` 的 daemon + thin client 模式，也参考了 `LegacySystemPreferences` 和 `LegacyPreferences` 等经典偏好设置面板项目。
