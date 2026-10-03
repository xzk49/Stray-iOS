# 本地构建与安装

## 1. 环境与游戏

安装完整 Xcode，在 Xcode 设置的 Components 中准备 Metal Toolchain。使用 Apple Silicon Mac 的原生终端与 Python 3.11+。

```sh
./stray doctor
./stray setup --game /path/to/Stray.app --bundle-id dev.yourname.stray --team YOURTEAMID
./stray prepare
./stray build
```

`prepare` 校验 29 个输入文件，包括 13 个代码镜像和 16 个原始资源。版本、清单、大小或哈希不匹配即停止，原游戏不会被覆盖。流程只接受已测试的未加密、thin ARM64 1.6 (102) 构建；不会解密或移除其他版本的 DRM。

Metal 编译器通常由 `xcrun metal --version` 的 InstalledDir 自动定位。若定位失败，可指定实际 Metal toolchain 中与 `air-opt` 同目录的 `bin/metal`：

```sh
./stray setup --metal /path/to/Metal.xctoolchain/usr/metal/current/bin/metal
```

不需要 LIEF、额外 Python 包或第三方下载脚本。构建使用 Python 标准库与 Apple 开发工具。

## 2. 自己的签名

在自己的开发者账户中建立与 bundle ID 匹配的 App ID，并启用 Increased Memory Limit。为已登记的真机创建包含该权限的开发 provisioning profile，在本机钥匙串安装相应开发证书和私钥。

可在 Xcode 的 Signing & Capabilities 中检查 App ID 和团队，并添加 Increased Memory Limit。仓库 Xcode 工程用于构建宿主；单独点击 Run 不会装配完整游戏。完整流程使用 `./stray`。

```sh
security find-identity -v -p codesigning
./stray setup --profile /path/to/YourStray.mobileprovision --identity YOUR_CERTIFICATE_SHA1
./stray package
```

将 `YOUR_CERTIFICATE_SHA1` 替换为匹配该 profile 的证书指纹。脚本验证 bundle ID、团队、有效期、证书和 Increased Memory Limit 权限；签名材料保持本地。它不要求把私钥或 profile 上传到 GitHub。

输出：

- `build/staging/StrayProbe.app`：完整、本地签名 App。
- `build/package/Stray-v21-local.ipa`：约 8.37 GB，本地完整资源 IPA。
- `build/package/verification.json`：归档、资源、CPU 策略和 Bink 验证结果。

IPA 采用 stored ZIP，避免大资源再次压缩；构建与打包会占用较多空间。此版未采用独立上传游戏资源的机制。

## 3. 真机安装

连接 iPhone，启用开发者模式并完成与 Mac 的信任。若首次安装后 iOS 提示未受信任，在系统设置中信任自己的开发者应用。

```sh
./stray devices
./stray install --device YOUR_DEVICE_ID
./stray launch --device YOUR_DEVICE_ID
```

设备 ID 可保存到本地配置：`./stray setup --device YOUR_DEVICE_ID`。它不会进入源码仓库。安装报开发者磁盘错误时，先检查 Xcode 与设备连接状态、重启后解锁一次，再重试安装。

升级使用同一个 bundle ID 和签名团队。在更换 ID、卸载或处理存档前，先通过 Xcode Devices/Finder 文件共享备份本地存档；卸载会清除 App 数据。

## 4. 设置与测试

进入原游戏图形设置选择 720p / 900p 与帧率上限。悬浮球只管理触屏手柄。启动默认读取游戏保存的图形设置；开发调试可用本地 `Documents/StrayRenderProfile.plist`，但普通使用不需要它。

```sh
./stray check
./stray check --game /path/to/Stray.app
```

第一条运行不依赖游戏资源的回归测试。第二条还检查实际电影配对与失败回退。

源代码变化或游戏路径变化后，重新运行 `prepare` 和 `build`；签名或 profile 变化后重新 `package`。脚本通过阶段记录阻止复用已失效的构建。

## 常见限制

- Increased Memory Limit 是系统授予的额度，不是固定比例或无限内存。运行时仍检查实际可用额度，并相应限制纹理池。
- 模拟器并未通过真实 Metal 场景验证，不能代替真机图形测试。
- 热机帧率可能很低。温控上限只是减少负载，不能把已经低于 30 FPS 的运行提高到 30 FPS。
- 当前仍有贴图、过场卡顿和长期稳定性问题。请参照 [已测范围](TESTING.md)，不要把本地打包成功当作全流程游玩通过。
