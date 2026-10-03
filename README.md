# Stray iOS

Experimental ARM64 macOS → iOS adaptation of **Stray 1.6 (102)**.

参考 [brolnickij/emu 的 SnowRunner 项目](https://github.com/brolnickij/emu)，将本地游戏的 ARM64 原生代码放入 iOS 宿主，通过 UIKit、Metal、音频和文件系统适配层运行。**当前是 v21 实验版本，已在真机进入菜单及三维关卡；尚未达到完整稳定、全关卡可玩的发布标准。**

这是源码和本地构建工具仓库。游戏本体、贴图、电影、原始或修改后的游戏二进制、商业着色器以及包含这些资源的 IPA，由使用者从自己拥有的指定版本安装中准备。仓库中的 MIT 许可证适用于本项目适配代码，第三方代码另见 [署名](THIRD_PARTY_NOTICES.txt)。

## 当前功能与状态

| 项目 | 状态 |
| --- | --- |
| 原游戏启动、主菜单、部分三维关卡 | 真机已验证 |
| 音频输出 | 已修复，用户确认声音正常 |
| Xbox 触屏手柄 | 原生 GameController 快照；基本菜单输入已验证 |
| 悬浮球 | 仅用于手柄布局、透明度、大小、灵敏度与死区设置 |
| 720p / 900p 设置 | 保留在游戏设置，保存值读取和真机启动已验证 |
| v20 启动闪退 | v21 修复 INI 字符串的错误数字转换，回归测试通过 |
| 温控 | Serious / Critical 临时限制 30 FPS；Serious 真机生效已验证 |
| 三段电影选择 1080p 原始资源 | 文件/时序校验通过，实际播放改善待验证 |
| 720p60 / 900p40–50 | **目标，尚未达成或验证** |
| 地面、水、管道、菜单猫的材质/阴影 | 仍有异常 |
| 过场与关卡切换卡顿、长时间稳定性 | 仍需修复和复测 |

完整已测范围和性能样本见 [测试记录](docs/TESTING.md)。分辨率和帧率选项的存在不代表实际帧率达到该值。

## 要求

- Apple Silicon Mac，Python 3.11+，完整 Xcode 和 Metal Toolchain 组件。发布整理时使用 Xcode 26.6、Python 3.13。
- 自己拥有的 **Stray macOS ARM64 1.6 (102)** 安装。`data/supported-game.json` 固定了 29 个输入文件的大小和 SHA-256；其他版本会被拒绝。
- 真机与自己的 Apple 开发者签名、匹配的 App ID 和 provisioning profile。该 profile 需要授予 **Increased Memory Limit**；本项目不会改变系统内存上限。
- 已测设备：iPhone 17 / A19 / 8 GB / iOS 26.3。部署目标 17.0 不表示所有 iOS 17 设备可运行。
- 完整本地 IPA 约 8.37 GB。建议为准备副本、构建和打包预留至少 25 GB 空间，并为手机保留足够安装空间。

## 快速开始

```sh
git clone https://github.com/xzk49/Stray-iOS.git
cd Stray-iOS
chmod +x stray
./stray doctor
./stray setup --game /path/to/Stray.app --bundle-id dev.yourname.stray --team YOURTEAMID
./stray prepare
./stray build
./stray check --game /path/to/Stray.app
```

准备流程先验证版本、文件清单和哈希，再在 `build/` 内制作副本；源游戏保持只读。构建产生未签名的完整资源 App。详细签名与安装步骤见 [BUILD.md](docs/BUILD.md)：

```sh
./stray setup --profile /path/to/YourStray.mobileprovision --identity YOUR_CERTIFICATE_SHA1
./stray package
./stray devices
./stray install --device YOUR_DEVICE_ID
./stray launch --device YOUR_DEVICE_ID
```

`package` 会检查 profile、证书匹配与有效期，签名后检查签名、IPA 内全部文件哈希、资源、三个 Bink 库和已记录的 CPU 指令变更。安装成功与归档检查通过仍需后续真机游戏验证。

所有路径、签名和设备信息存于忽略的 `config.local.json`。生成的图标由本地 `Stray.icns` 转换，PNG 和完整构建产物也被忽略。

## 触屏手柄

映射参考 [Geocld/XStreaming](https://github.com/Geocld/XStreaming)，使用原生 `GCController` 可写快照：

| Xbox 控件 | iOS GameController |
| --- | --- |
| A / B / X / Y | buttonA / buttonB / buttonX / buttonY |
| LB / RB | leftShoulder / rightShoulder |
| LT / RT | leftTrigger / rightTrigger |
| 左右摇杆、L3 / R3 | thumbsticks / thumbstickButtons |
| 十字键 | dpad |
| View / Menu / Nexus | buttonOptions / buttonMenu / buttonHome |

悬浮球提供经典/紧凑布局、位置编辑、双指缩放、透明度、灵敏度和死区。布局保存于 `Documents/StrayTouchLayout.plist`。应用失活时释放触点；短按释放等待一次原生轮询并设定等待上限。该模块仅移植布局和输入映射，游戏在手机本地运行。

## 命令

| 命令 | 用途 |
| --- | --- |
| `doctor` | 工具链、Python、磁盘检查 |
| `setup` | 更新本地游戏、签名与设备配置 |
| `prepare` | 固定版本校验、Mach-O 副本、适配库、Bink 和图标准备 |
| `build` | Xcode 宿主构建、依赖路由、完整资源装配 |
| `package` | 本地签名、生成并验证 IPA |
| `devices` | 列出已连接设备 |
| `install` / `launch` | 安装或启动本地签名 App |
| `check` | 源码清单、配置解析、温控、电影策略回归测试 |

本版采用完整资源 App/IPA 安装；尚未实现 SnowRunner 的独立资源增量传输命令。更新时使用相同 bundle ID 和签名团队，避免删除 App 导致存档丢失；调试前应自行备份存档。

## 结构与原理

```text
app/                         UIKit 宿主、兼容层和底层准备脚本
app/StrayProbe.xcodeproj/     Xcode 工程（签名团队留空）
app/tests/                   配置解析、温控与电影测试
tools/                       统一工作流和发布清单检查
data/supported-game.json     指定版本的输入哈希与 UUID
docs/                        构建、已测范围和限制
config.example.json          不含个人信息的配置模板
build/                       本地生成目录（不入库）
```

这条路径直接运行 ARM64 代码，没有 CPU 模拟或 JIT。把 macOS Mach-O 制作成 iOS 加载副本，处理加载命令和依赖路径；AppKit/Carbon/Cocoa 的已观察 API 子集由适配库提供。Metal 适配处理 unified-memory 存储、深度格式和生命周期；音频适配到 RemoteIO，同时保留游戏的 mixer 回调。

只有三处已记录的 CPU 策略变更：资源目录布局、Mac 卷拒绝分支、缺少 Mac PCI GPU 描述符的空指针保护。每处修改检查原字节并生成前后记录。Bink 的三个内嵌 Metal 库在本地由原始 AIR 重新编译，同时验证函数运算和资源绑定。其余 UE4 Metal 容器的适配仍存在材质兼容问题。

本项目针对一个固定游戏构建，所实现的 Cocoa/AppKit 子集不适用于任意 Mac 应用。模拟器的早期 NullRHI 启动测试不能验证 Metal 场景；现有 cube-array 等限制仍在。

## 已知问题 / 后续工作

- 修复菜单猫的阴影/材质，以及地面、水、管道贴图。
- 调查同步 Metal pipeline 创建造成的关卡切换停顿。
- 复测三段 1080p 过场的真实播放、音画同步和缓冲区故障路径。
- 冷机/持续负载分别测量真实游戏帧率、内存和发热；验证温控降温恢复。
- 覆盖其他关卡、存档加载和长时间稳定性。历史测试出现过内存压力退出，v21 不代表所有闪退已修复。

问题报告请附设备型号、iOS/Xcode 版本、游戏版本、复现步骤与已去除个人路径和设备信息的日志片段。

## 致谢与许可证

- [brolnickij/emu](https://github.com/brolnickij/emu)：SnowRunner ARM64 本地适配与源码发布方式的参考。
- [Geocld/XStreaming](https://github.com/Geocld/XStreaming)：Xbox 触屏布局与映射参考，MIT 署名全文保留于 `THIRD_PARTY_NOTICES.txt`。
- Stray 与游戏资源归其相应权利人所有。本项目为非官方兼容性实验，与 BlueTwelve Studio、Annapurna Interactive、Apple 或 Xbox 无隶属关系。

本项目源码：[MIT](LICENSE)。
