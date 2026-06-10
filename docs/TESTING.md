# Volume Limiter 测试报告

测试日期：2026-06-10  
测试机器：macOS Darwin 25.5.0，arm64，Command Line Tools Swift 6.0.3  
当前限制：本机只有 Command Line Tools，没有完整 Xcode；prefPane 使用 `swiftc` 手工构建，不使用 `xcodebuild`。系统设置视觉确认、截图、键盘音量键、蓝牙耳机、重启验证需要人工交互，未伪造结果。

## 1. 自动化与本机 smoke 测试

| 项目 | 命令 | 预期结果 | 实际结果 |
| --- | --- | --- | --- |
| 构建 SwiftPM 工程 | `swift build` | 构建成功 | 成功 |
| Core/IPC/CLI 自检 | `swift run volume-limiter-tests` | 所有测试通过 | 16 项全部通过 |
| daemon + CLI 实机 smoke | `scripts/test-cli-daemon.py` | daemon 启动，CLI 可用，重复 daemon 被拒绝 | 成功 |
| prefPane 构建 | `scripts/build-prefpane.sh` | 生成 ad-hoc 签名 `.prefPane` | 成功 |
| prefPane 安装 | `scripts/install-prefpane.sh` | 安装到 `~/Library/PreferencePanes` | 成功 |
| Release 打包 | `scripts/build-release.sh 0.1.0` | 生成 CLI/daemon zip、GUI zip、SHA256SUMS | 成功 |
| 本地 Homebrew Formula 模拟安装 | 临时 tap + 本地 tarball + `brew install` | 安装并启动 service | 阻塞：Homebrew 要求更新 Command Line Tools 到 Xcode 26.3 |

`swift run volume-limiter-tests` 关键输出：

```text
PASS Core clamps startup volume above limit
PASS Core clamps on volume-change callback
PASS Core bluetooth-only skips non-Bluetooth devices
PASS Core bluetooth-only clamps Bluetooth devices
PASS Core rejects invalid limit
PASS Core disabled limiter does not clamp
PASS Core config store persists settings
PASS IPC request/response Codable round trip
PASS IPC Unix socket handles newline JSON
PASS IPC server returns structured error for invalid JSON
PASS IPC rejects active duplicate socket server
PASS CLI set sends setLimit request
PASS CLI get renders compact daemon status
PASS CLI rejects invalid limit locally
PASS CLI maps daemon connection failure
PASS CLI talks to server over Unix socket
All 16 Volume Limiter tests passed.
```

`scripts/test-cli-daemon.py` 关键输出：

```text
$ volume-limit status
Volume Limiter daemon: running
Enabled: on
Limit: 50%
Current volume: 0%
Device: MacBook Air扬声器
Bluetooth-only: off
Device is Bluetooth: no
Volume control available: yes
Notify on limit: off
Diagnostics: none
$ volume-limit set 100
Limit set to 100%.
$ volume-limit get
Limit: 100%
Current volume: 0%
Device: MacBook Air扬声器
Enabled: on
Bluetooth-only: off
$ volume-limit off
Volume limiting is off.
$ volume-limit on
Volume limiting is on.
$ volume-limit bluetooth-only status
Bluetooth-only mode is off.
$ volume-limiterd # duplicate
volume-limiterd: failed to start: bind failed: Address already in use
$ volume-limit status # daemon stopped
volume-limiterd is not running.
Start it with: brew services start volume-limiter
```

## 2. IPC 与单实例约束

| 项目 | 预期结果 | 实际结果 |
| --- | --- | --- |
| 默认 socket 路径 | 使用 `/tmp/volume-limiter-$UID.sock` | 已使用 |
| socket 权限 | daemon 创建后 chmod `0600` | 已实现 |
| JSON 行协议 | 请求/响应各占一行 JSON | 自检通过 |
| 非法 JSON | 返回结构化错误 | 自检通过 |
| 未知/非法参数 | daemon 拒绝并返回错误 | 已实现 `unsupportedVersion`、`unknownCommand`、`missingArgument`、`invalidArgument` |
| 重复 daemon | 当前用户会话只允许一个活动 socket server | 自检和实机 smoke 均通过 |
| SIGPIPE | 对端提前关闭不能杀死 daemon | 已修复并通过冲突测试 |

## 2.1 Release artifacts

| 项目 | 命令 | 预期结果 | 实际结果 |
| --- | --- | --- | --- |
| CLI universal 架构 | `lipo -archs .build/release-artifacts/volume-limiter-cli-v0.1.0/volume-limit` | `x86_64 arm64` | `x86_64 arm64` |
| daemon universal 架构 | `lipo -archs .build/release-artifacts/volume-limiter-cli-v0.1.0/volume-limiterd` | `x86_64 arm64` | `x86_64 arm64` |
| CLI zip 内容 | `unzip -l .build/release-artifacts/volume-limiter-cli-v0.1.0.zip` | 只包含 `volume-limit` 和 `volume-limiterd` | 成功，不包含短别名 |

## 3. Core Audio 封顶逻辑

| 项目 | 预期结果 | 实际结果 |
| --- | --- | --- |
| 默认输出设备状态 | daemon 可读取真实设备状态 | 成功，设备为 `MacBook Air扬声器` |
| 音量封顶业务逻辑 | 超过 limit 时回压到 limit | 使用 fake audio adapter 自检通过 |
| 音量变化回调 | 回调触发后立即回压 | 使用 fake audio adapter 自检通过 |
| 程序化触发回压延迟 | 设置 limit 20%，脚本触发到 30%，目标 `<100ms` | `clamp-latency-ms=9.66`，通过 |
| 键盘音量键回压延迟 | 设置 limit 20%，人工按音量增大键，目标 `<100ms` | `clamp-latency-ms=5.06`，通过 |
| Bluetooth-only | 非蓝牙跳过，蓝牙设备生效 | 使用 fake audio adapter 自检通过 |
| 蓝牙输出识别 | 连接并切换到 OPPO Enco Free4，运行 `volume-limit status` | `Device is Bluetooth: yes`，通过 |
| 蓝牙设备超限回压延迟 | OPPO Enco Free4，limit 20%，脚本触发到 35%，目标 `<100ms` | `clamp-latency-ms=22.01`，通过 |
| 蓝牙断开/重连后封顶 | OPPO Enco Free4 在限制关闭时设到 55%，断开；重新启用限制后重连 | 重连后 `Current volume: 20%`，通过 |
| Type-C 有线耳机 | Poly Blackwire 3325 Series，limit 20%，脚本触发到 35%，目标 `<100ms` | `Volume control available: yes`，`clamp-latency-ms=63.63`，通过 |
| 不支持音量控制诊断 | status 暴露 diagnostics | 代码路径已实现；真实硬件未覆盖 |

尚未完成的真实交互项：

| 项目 | 未执行原因 | 手动验证命令/步骤 |
| --- | --- | --- |
| HDMI/AirPlay/aggregate device 或不支持系统音量控制设备 | 需要对应外设 | 切换输出设备后运行 `volume-limit status` 查看 diagnostics |

## 4. CLI 前端

| 命令 | 预期结果 | 实际结果 |
| --- | --- | --- |
| `volume-limit set <0-100>` | 通过 socket 设置上限 | 实机 smoke 通过 |
| `volume-limit get` | 显示上限、当前音量、设备名 | 实机 smoke 通过 |
| `volume-limit on/off` | 启停封顶 | 实机 smoke 通过 |
| `volume-limit status` | 显示 daemon 和设备状态 | 实机 smoke 通过 |
| `volume-limit bluetooth-only status` | 显示蓝牙模式 | 实机 smoke 通过 |
| daemon 未运行 | 显示启动提示并退出 69 | 实机 smoke 通过 |

daemon 未运行时实际输出：

```text
volume-limiterd is not running.
Start it with: brew services start volume-limiter
```

## 5. prefPane GUI

| 项目 | 命令 | 预期结果 | 实际结果 |
| --- | --- | --- | --- |
| 构建 universal prefPane | `scripts/build-prefpane.sh` | 生成 arm64 + x86_64 bundle | 成功 |
| 检查架构 | `lipo -archs .build/prefpane/VolumeLimiter.prefPane/Contents/MacOS/VolumeLimiter` | `x86_64 arm64` | `x86_64 arm64` |
| 检查 bundle 类型 | `otool -hv ...` | `BUNDLE` | `BUNDLE` |
| 检查 plist | `plutil -lint .../Info.plist` | OK | OK |
| 检查签名 | `codesign --verify --deep --strict --verbose=2 ...` | ad-hoc 签名有效 | 成功 |
| 安装 | `scripts/install-prefpane.sh` | 安装到用户 PreferencePanes | 成功 |
| Bundle 加载 | `Bundle(path: ...).load()` | true | `bundle-loaded=true` |
| Principal class | `bundle.principalClass` | prefPane class | `VolumeLimiterPrefPane.VolumeLimiterPreferencePane` |
| 系统设置打开请求 | `open ~/Library/PreferencePanes/VolumeLimiter.prefPane` | System Settings 打开该 pane | 命令退出 0 |
| 系统设置视觉确认 | 人工检查 System Settings 面板 | 面板显示完整控件，无底部裁切 | 成功；首次发现 `Diagnostics` 底部裁切，已通过加高主视图和压缩间距修复 |
| 系统设置截图 | `screencapture -x docs/screenshots/prefpane-system-settings.png` | 保存真实截图 | 成功，路径见下方 |

截图：

```text
docs/screenshots/prefpane-system-settings.png
```

prefPane UI 已包含：

- 音量上限滑块，修改后通过 IPC 调用 `setLimit`。
- 当前音量显示，通过 IPC 读取 daemon status。
- “Only limit Bluetooth outputs” 开关，通过 IPC 调用 `setBluetoothOnly`。
- “Start daemon at login” 开关，通过同一 LaunchAgent label `com.hackwoodl.volumelimiter` 调用 `launchctl` 管理。
- “Notify when volume is limited” 开关，通过 IPC 调用 `setNotifyOnLimit`。

## 6. 资源占用

命令：启动 `.build/debug/volume-limiterd`，空闲 5 秒后执行：

```bash
ps -o pid=,%cpu=,rss=,comm= -p <pid>
```

实际输出：

```text
5167   0.0  12816 /Users/you/Documents/workspace/6_10_volume_limiter/.build/debug/volume-limiterd
```

结论：该样本中 daemon 空闲 CPU 为 `0.0%`，RSS 约 `12.5 MB`。这不是 Instruments 长时间功耗报告，后续发布前仍应补充更长时间采样。

## 7. 边界测试

| 项目 | 预期结果 | 实际结果 |
| --- | --- | --- |
| limit 0 | 允许设置，超限回压到 0 | 参数校验允许；真实设备回压未手测 |
| limit 100 | 允许设置，不应压低当前音量 | 实机 smoke 设置 `100` 成功 |
| invalid limit 101 | CLI 本地拒绝，不发 IPC | 自检通过 |
| 设备不支持 VolumeScalar | status diagnostics 暴露原因 | 代码路径已实现；缺少真实设备覆盖 |

## 8. 开机自启、分装与卸载

这些项目依赖后续 GitHub Release、Homebrew tap 和重启流程，尚未执行：

| 项目 | 当前状态 | 后续验证方式 |
| --- | --- | --- |
| LaunchAgent 开机自启 | prefPane 已实现同 label 的开关；未重启验证 | 安装 formula 后启用开关，重启，再运行 `volume-limit status` |
| 只装 CLI | Formula 已准备；本地临时 tap 安装已尝试但被 Homebrew 拦截 | 更新 Command Line Tools 到 Xcode 26.3 后重试，或发布 tag/release 后 `brew install HackwoodL/tap/volume-limiter` |
| 只装 GUI 自动带 daemon | Cask 已准备；GUI zip SHA 尚未发布替换；依赖 Formula 安装 | Formula 可安装后再执行 `brew install --cask HackwoodL/tap/volume-limiter-gui` |
| 分别卸载与 zap | 需要真实 tap 安装成功后验证 | 发布后执行 uninstall/zap 流程 |

本地 Formula 验证的实际阻塞输出：

```text
Error: Your Command Line Tools are too outdated.
Update them from Software Update in System Settings.
...
You should download the Command Line Tools for Xcode 26.3.
```

## 9. 结论

已完成并真实验证：Core/IPC/CLI 自动化测试、真实 daemon + CLI smoke、单实例冲突、prefPane 构建/签名/安装/Bundle 加载、System Settings 视觉确认和截图、键盘音量键 `<100ms` 回压延迟、基础资源占用采样。

尚需人工或后续阶段验证：HDMI/AirPlay/聚合设备/不支持音量控制设备、重启自启、Homebrew 分装与卸载（当前本机被 Command Line Tools 版本阻塞）。
