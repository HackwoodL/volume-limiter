# Volume Limiter

[English](README.md)

![Volume Limiter 系统设置面板截图](docs/screenshots/prefpane-system-settings.zh-CN.png)

Volume Limiter 是一个轻量级 macOS 最大音量限制器。它通过单一的当前用户守护进程监听 Core Audio 输出设备和音量变化，一旦当前输出音量超过你设置的上限，就立即压回上限。CLI 和 GUI 都是瘦客户端，只通过 Unix domain socket 与同一个守护进程通信。

## 功能

- 事件驱动的 Core Audio 监听；默认不轮询。
- 当前用户会话内单一守护进程 `volume-limiterd`，随安装自启、空闲 CPU 接近 0%。
- CLI：`volume-limit`。
- GUI：集成到 macOS“系统设置”的 ad-hoc 签名 `VolumeLimiter.prefPane`，顶部总开关一键启停封顶。
- prefPane 可见时自动刷新状态，离开面板后停止刷新。
- 配置由 daemon 统一持有，CLI 和 GUI 天然同步。
- 支持“仅耳机输出时生效”模式，覆盖蓝牙耳机、USB/Type-C 耳机等常见耳机输出。
- 分设备上限：默认上限适用于所有设备，可为特定设备单独设置上限。
- 支持音量被压回时发送 macOS 通知。
- 面板内置一键「卸载」按钮，一步移除后台服务、配置和面板本身。
- 不安装内核扩展、不安装虚拟音频驱动、不依赖任何付费证书。

## 安装

### 推荐：本地安装（当前可用）

```bash
git clone https://github.com/HackwoodL/volume-limiter.git
cd volume-limiter
scripts/install-local.sh
```

`install-local.sh` 会构建 universal 二进制，并把所有东西装进 App 专属的
`~/Library/Application Support/VolumeLimiter`（LaunchAgent 和 prefPane 在 `~/Library` 下）。
它会注册一个开机自启的 LaunchAgent，不会从你的源码目录里运行任何东西。
之后若只想更新 GUI，单独运行 `scripts/install-prefpane.sh` 即可。

CLI 安装在 `~/Library/Application Support/VolumeLimiter/bin`，把它加进 `PATH` 后即可直接用 `volume-limit`：

```bash
echo 'export PATH="$HOME/Library/Application Support/VolumeLimiter/bin:$PATH"' >> ~/.zshrc
```

### Homebrew（计划中，尚未发布）

个人 tap 发布后，以下命令即可使用：

```bash
brew install HackwoodL/tap/volume-limiter              # CLI + daemon
brew services start volume-limiter
brew install --cask HackwoodL/tap/volume-limiter-gui   # prefPane GUI
```

### 从源码构建

```bash
swift build
swift run volume-limiter-tests
scripts/test-cli-daemon.py
```

### GitHub Release 手动安装

> 发布 GitHub Release 后可用；在那之前请用上面的本地安装。

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

因为我没钱买 Apple 开发者签名（Apple Developer Program），所以发布版本只做 ad-hoc 签名，不走 Developer ID，也不做 notarization。因此首次打开时 macOS 可能需要你右键打开、执行 `xattr -cr`，或在系统设置中选择“仍要打开”。

## CLI

```bash
volume-limit set <0-100>            # 设置适用于所有设备的默认上限
volume-limit on                     # 开启限制器
volume-limit off                    # 关闭限制器
volume-limit status                 # 打印守护进程完整状态和诊断信息
volume-limit device on|off          # 开启/关闭分设备上限功能
volume-limit device set <uid> <n>   # 为指定 UID 的设备单独设置上限
volume-limit device remove <uid>    # 移除某个设备的单独上限
volume-limit device list            # 列出各设备上限与已连接设备
volume-limit headphone-only on|off  # 仅限制耳机类输出设备
volume-limit --help                 # 显示用法
```

如果 daemon 没有运行，CLI 会提示：

```text
volume-limiterd is not running.
Start it from System Settings > Volume Limiter, or with Homebrew: brew services start volume-limiter
```

## 卸载

### 最简单：卸载按钮（图形界面）

打开 系统设置 ▸ Volume Limiter，点击面板底部的 **Uninstall（卸载）** 按钮即可。它会一步停掉后台服务，并删除 LaunchAgent、保存的配置以及偏好设置面板本身。之后请退出并重新打开「系统设置」，即可将其从侧边栏清除。

### 本地安装（终端）

与按钮等效，如果你更习惯命令行：

```bash
launchctl bootout gui/$(id -u)/com.hackwoodl.volumelimiter 2>/dev/null || true
rm -rf ~/Library/Application\ Support/VolumeLimiter \
       ~/Library/PreferencePanes/VolumeLimiter.prefPane \
       ~/Library/LaunchAgents/com.hackwoodl.volumelimiter.plist
```

### Homebrew（发布后）

```bash
brew uninstall --cask volume-limiter-gui || true
brew services stop volume-limiter || true
brew uninstall volume-limiter || true
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

## 测试

详见 [`docs/TESTING.md`](docs/TESTING.md)。当前已经覆盖 Core 逻辑测试、通知触发测试、IPC 协议测试、CLI 解析/输出测试、Unix socket 冲突测试、真实 daemon + CLI smoke、prefPane 构建/签名/加载、系统设置截图、键盘音量键延迟、蓝牙重连、Type-C 有线耳机、重启自启和基础资源采样。

仍需后续条件满足后验证：HDMI/AirPlay/聚合设备/不支持系统音量控制设备，以及发布真实 GitHub Release/Homebrew tap 后使用正式 URL/SHA 的安装/卸载流程。

## prefPane 状态说明

`NSPreferencePane` 已被 Apple 标记为 deprecated。Volume Limiter v1 仍优先使用它，因为它能在当前 macOS 上提供最接近“系统设置”的集成体验。如果未来 macOS 移除或进一步限制第三方 prefPane，fallback 方案是 SwiftUI 菜单栏 App，但仍保持同一个 daemon + IPC 瘦客户端架构。

## Roadmap

- v0.1.x：完成发布打包、tap 发布和剩余硬件验证。
- v1.0：CLI 与 prefPane GUI 都有稳定的分发渠道（Homebrew tap 与 GitHub Release）。
- v2：研究驱动层硬拦截，例如 Core Audio HAL 虚拟设备。v1 明确不安装驱动、kext 或虚拟音频设备。
