# WhatsAppDeviceAgent（iOS 工程）

本目录即独立仓库 `whatsapp_ai_ios`（由 whatsapp_ai 主仓迁移而来）的根目录，
`.git` / README / docs / scripts / .gitignore 全部收敛于此。
iPhone App + Network Extension（PacketTunnel）通过 easytier 组网接入平台 `10.168.0.0/16` 虚拟网络，
注册/配置下发/心跳/组网状态走平台 `/api/ios-agent/v1` 接口。
与平台主仓（whatsapp_ai）的接口契约：`/api/ios-agent/v1`（enroll / config / status / token/rotate），
平台地址默认 `https://hk.hsddns.com`（注册页可改）。
（工程基于 `docs/design/2026-08-06-ios-whatsapp-broadcast-vpn.md` 第 6 章搭建。）

## 仓库结构（设计 6.1）

```text
WhatsAppDeviceAgent.xcodeproj    Xcode 工程（App + PacketTunnel Extension + 2 个测试 target）
Configs/                        Base/Debug/Release.xcconfig（统一 bundle 前缀、iOS 16.4、EASYTIER_IO_MODE）
Vendor/EasyTier/                include/easytier_ffi.h（人工维护 ABI）、SOURCE_COMMIT、LICENSE 占位、EasyTierFFI.xcframework（构建产物，gitignore）
Shared/                         App 与 Extension 共用：配置/状态模型、Keychain、App Group、API/WSS、脱敏日志
WhatsAppDeviceAgent/             主 App：注册页、状态页、VPN profile、enrollment
PacketTunnel/                   Network Extension：生命周期、EasyTier Bridge、TOML builder、fd/packetFlow 桥
WhatsAppDeviceAgentTests/        主 App 单元测试
PacketTunnelTests/               Extension 单元测试
docs/                           设计 / 测试 / 部署文档
scripts/                        EasyTier iOS XCFramework 构建脚本与 fork patch
```

## 打开与运行

1. 打开 `WhatsAppDeviceAgent.xcodeproj`（需要 Xcode 16+）。
2. 首次克隆后先构建 EasyTier FFI（XCFramework 为构建产物、不入库），见下文「构建 EasyTier FFI」。
3. Scheme 选 `WhatsAppDeviceAgent`，选择模拟器或真机运行。
   - 模拟器：直接 Run，注册用手动输入注册码（模拟器无摄像头）。
   - 真机：Signing 填 Apple Team、iPhone 开启开发者模式；Network Extension（VPN）需付费开发者账号。
     更换 bundle 前缀时，App/Extension/App Group/Keychain group 必须成组修改（设计 6.1）。
4. 当前 M3 接线状态：`EasyTierRuntime.isLinked == true`，Debug（fd 轨）已接入
   easytier FFI（parse → run → set_tun_fd → collect），真机组网可跑通；
   Release（packetFlow 轨）为 M0-E 预留，启动 VPN 会明确失败，不伪在线。

## 构建 EasyTier FFI（M0-A 前置，一次性）

`Vendor/EasyTier/EasyTierFFI.xcframework` 是构建产物（已 gitignore，不入库），首次克隆本仓库后需本地构建：

1. 安装 Rust 1.95。
2. 在本目录（仓库根目录）准备本地克隆（已被 `.gitignore` 忽略）：

```bash
mkdir -p third_party
git clone https://github.com/EasyTier/EasyTier.git third_party/easytier
cd third_party/easytier
git checkout 8428a89d2dabc94c97d370ec607c6ca142473626   # 与 Vendor/EasyTier/SOURCE_COMMIT 一致（v2.6.4）
git apply ../scripts/easytier-fork-v2.6.4-8428a89d.patch
cd ..
```

3. 构建并核验导出符号：

```bash
rtk bash scripts/build-easytier-ios.sh
rtk bash scripts/verify-easytier-ffi-symbols.sh
```

4. 产物写入 `Vendor/EasyTier/EasyTierFFI.xcframework`（+ `.sha256`），
   供 App / PacketTunnel target 链接。

## 验证命令（从本目录执行）

```bash
rtk xcodebuild -project WhatsAppDeviceAgent.xcodeproj -list
rtk xcodebuild -project WhatsAppDeviceAgent.xcodeproj \
  -scheme WhatsAppDeviceAgent -sdk iphonesimulator -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

> 说明：
> - 推荐直接在 Xcode 中打开工程用 Scheme `WhatsAppDeviceAgent` 构建/运行；
>   Xcode 会自动处理 App/Extension/测试 target 依赖与 module 路径。
> - 命令行 `xcodebuild -target` 属于 legacy 模式，不会为测试 target 注入
>   `@testable import` 所需的依赖 module 路径；请改用 `-scheme` + destination 构建：
>   `xcodebuild -project WhatsAppDeviceAgent.xcodeproj -scheme WhatsAppDeviceAgent -destination 'generic/platform=iOS Simulator' build`
> - 本机未安装 iOS 模拟器 runtime，只能编译验证；有 runtime 后可执行 `xcodebuild test`。

## 文档

- 设计：`docs/design/2026-08-06-ios-whatsapp-broadcast-vpn.md`（主设计）、
  `docs/design/2026-08-04-iphone-whatsapp-broadcast-feasibility.md`（可行性）、
  `docs/design/2026-08-10-ios-solution-review.md`（方案评审）
- 测试：`docs/testing/2026-08-10-ios-real-device-onboarding.md`（真机接入 HK 测试平台）、
  `docs/testing/2026-08-06-ios-easytier-wda-m0.md`
- 部署：`docs/deployment/ios-device-enroll-test-sop.md`

## 与平台主仓（whatsapp_ai）的关系

- 接口契约：`/api/ios-agent/v1`（enroll / config / status / token/rotate）；平台默认 `https://hk.hsddns.com`。
- easytier 服务端运维（`deploy-easytier-test.sh`、HK 服务器部署）属平台侧，不在本仓库。
