# NetPulse 项目说明

## 项目定位

NetPulse 是一个轻量的 macOS 状态栏网速监控应用。它会在菜单栏实时显示下载和上传速度，并提供一个 SwiftUI 详细面板，用于查看当前网络状态、历史趋势、高流量进程、登录自启和高速下载提醒设置。

项目使用 Swift Package Manager 构建，最低运行平台为 macOS 13，Swift 语言模式为 Swift 6。主要使用的系统框架包括 AppKit、SwiftUI、Charts、Network、SystemConfiguration、ServiceManagement 和 UserNotifications。

## 常用命令

```bash
swift run
```

直接从源码运行应用，适合开发调试。通过这种方式运行时，登录自启等依赖正式 `.app` 包的系统集成功能会受限。

```bash
swift test
```

运行测试。当前测试主要覆盖速度格式化、刷新间隔选项、下载提醒默认偏好，以及 `nettop` CSV 输出解析。

```bash
./scripts/package_app.sh
```

构建 release 版本并打包为 macOS 应用。输出位置为 `dist/NetPulse.app`，图标源文件为 `Resources/AppIcon.png`。

## 目录结构

- `Sources/NetPulse`：主应用源码，包含 AppKit 启动入口、SwiftUI 面板、网络采样、进程流量、通知提醒和登录自启逻辑。
- `Tests/NetPulseTests`：Swift Testing 测试代码。
- `scripts`：辅助脚本，包括 `.app` 打包脚本和 `.icns` 图标生成脚本。
- `Resources`：应用资源，目前包含打包时使用的 `AppIcon.png`。
- `docs`：README 使用的 logo、banner 和截图素材。
- `.build`：SwiftPM 构建产物，已被 `.gitignore` 排除。
- `dist`：打包后的应用输出目录，已被 `.gitignore` 排除。

## 核心模块

### 应用入口与生命周期

- `main.swift` 创建 `NSApplication`，设置 `AppDelegate`，并将应用激活策略设为 `.accessory`，使 NetPulse 作为菜单栏应用运行。
- `AppDelegate` 负责应用生命周期、状态栏按钮、浮动设置面板、偏好绑定、睡眠/唤醒事件处理，以及面板打开和关闭时的资源启停。
- 状态栏内容由自定义 `NSStatusBarButton` 子视图组成，包含模板图标和等宽数字文本。状态栏宽度使用“最小宽度 + 超出后分级扩展”的策略，减少常见速度变化造成的抖动。

### 网络采样

- `NetworkTrafficMonitor` 通过 `NWPathMonitor` 判断联网状态，并定时读取网卡流量快照。
- 采样间隔来自 `RefreshIntervalOption`，支持 0.5 秒、1 秒和 2 秒。修改采样间隔会重启定时器、清空历史曲线并重置平滑缓冲。
- 下载和上传速度基于两次网卡字节计数差值计算，并使用最近 3 次样本做简单平均平滑。
- 睡眠前会暂停采样并清零速度；唤醒后会重新检查网络路径和网卡状态。

### 网卡读取

- `InterfaceSnapshotReader` 使用 `getifaddrs` 读取 AF_LINK 网卡统计数据，累计 `ifi_ibytes` 和 `ifi_obytes`。
- 默认仅支持 `en` 前缀的网卡，并排除 loopback、utun、vmnet、vnic 等虚拟或非目标接口。
- 网卡展示名通过 `SystemConfiguration` 的 `SCNetworkInterfaceCopyAll` 解析，优先显示系统本地化名称，同时保留 BSD 名称。
- 支持自动选择活动网卡，也支持在面板中手动锁定指定网卡。若锁定的网卡不可用，会自动回到自动选择。

### 面板界面

- `StatusPopoverView` 是主要 SwiftUI 面板，展示 NetPulse 标题、连接摘要、下载/上传速度卡片、Charts 历史曲线、高流量进程和设置项。
- 面板中可配置状态栏显示模式、刷新间隔、网卡选择、登录自启和高速下载提醒。
- 历史曲线会再次对展示数据做短窗口平均，并标记下载和上传峰值。

### 高流量进程

- `ProcessTrafficMonitor` 只在面板打开时启动，关闭面板时停止，避免常驻运行 `nettop`。
- 进程监控通过 `/usr/bin/nettop -P -x -d -s 1 -L 0` 获取 CSV 风格输出。
- 解析逻辑会提取进程名、PID、下载字节每秒和上传字节每秒，并过滤 `nettop` 与 `NetPulse` 自身，最终展示总流量最高的前 3 个进程。

### 下载提醒

- `DownloadAlertMonitor` 管理高速下载提醒逻辑和通知权限状态。
- 下载提醒支持阈值、冷却时间和持续时长配置。默认偏好为关闭、阈值 1 M/s、冷却 1 分钟、持续 20 秒。
- 启用后，只有在已获得通知权限且下载速度连续超过阈值达到指定时长时，才会发送系统通知。
- 如果通知权限被拒绝，面板会显示提示并提供打开系统通知设置的入口。

### 登录自启

- `LaunchAtLoginController` 使用 `SMAppService.mainApp` 控制登录项。
- 登录自启只在应用以打包后的 `.app` 形式运行时可用；通过 `swift run` 启动时会显示不可用提示。
- 当 macOS 返回 `requiresApproval` 时，需要用户在“系统设置 > 通用 > 登录项”中批准。

### 偏好与格式化

- `AppPreferences` 使用 `UserDefaults` 持久化状态栏显示模式、网卡选择、刷新间隔、下载提醒配置，以及最近一次菜单栏显示状态。
- `SpeedFormatter` 统一处理速度显示格式，分别提供菜单栏、紧凑和详细三种输出风格。

## 开发注意事项

- 这个项目没有外部服务依赖，不需要云账号或 API Key。
- 修改菜单栏展示时，要注意状态栏宽度策略，避免频繁宽度跳变或裁切文本。
- 修改采样间隔、网卡选择或睡眠/唤醒逻辑时，要考虑历史数据、平滑缓冲和上一帧快照是否需要重置。
- 进程流量监控应保持“面板打开时启动、面板关闭时停止”的行为，避免后台持续运行 `nettop`。
- 登录自启功能需要在打包后的 `NetPulse.app` 中验证，不能只依赖 `swift run`。
- 下载提醒相关变更需要同时考虑阈值、冷却、持续时长、通知授权状态和详情文案。
- 打包脚本会生成 `dist/NetPulse.app`，并使用 ad-hoc codesign 签名。
- `scripts/package_app.sh` 当前会删除并重建目标 app bundle；如果需要改动脚本，注意项目偏好中禁止批量删除文件或目录，应先和用户确认。

## 验证记录

本次梳理时尝试运行过：

```bash
swift test
```

命令在当前沙箱环境中失败，原因是 Swift/Clang 试图写入 `~/.cache/clang/ModuleCache`，但该路径不允许写入，报错包含 `Operation not permitted`。这不是测试断言失败。正常开发环境中，仍应使用 `swift test` 作为主要回归验证命令。

## 仓库与忽略项

- 当前目录是 Git 工作目录，存在 `.git` 元数据。
- `.gitignore` 已排除 `.build`、`dist`、DerivedData、SwiftPM 本地配置、`.netrc` 和常见 Xcode 用户数据。
