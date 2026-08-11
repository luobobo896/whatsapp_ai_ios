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
WhatsAppDeviceAgent.xcodeproj    Xcode 工程（App + PacketTunnel Extension + 3 个测试 target）
Configs/                        Base/Debug/Release.xcconfig（统一 bundle 前缀、iOS 16.4、EASYTIER_IO_MODE）
Shared/                         App 与 Extension 共用：配置/状态模型、Keychain、App Group、API 客户端、脱敏日志
WhatsAppDeviceAgent/             主 App：注册、状态页、VPN profile、enrollment
PacketTunnel/                   Network Extension：隧道生命周期、EasyTier Bridge、TOML builder、fd/packetFlow 桥
WhatsAppDeviceAgentTests/        主 App 单元测试
PacketTunnelTests/               Extension 单元测试
WhatsAppDeviceAgentUITests/      UI 测试（真实注册 HK 平台）
Vendor/EasyTier/                include/easytier_ffi.h（人工维护 ABI）、SOURCE_COMMIT、LICENSE 占位、EasyTierFFI.xcframework（构建产物，gitignore）
docs/                           设计 / 测试 / 部署文档
scripts/                        EasyTier iOS XCFramework 构建脚本与 fork patch
```

### 各模块职责

#### `Configs/` — 构建设置（xcconfig）

- `Base.xcconfig`：统一部署目标 iOS 16.4、Swift 5.0、bundle 前缀
  （`APP_BUNDLE_ID` / `EXT_BUNDLE_ID` / `APP_GROUP_ID` / `KEYCHAIN_GROUP_ID`）、I/O 模式开关 `EASYTIER_IO_MODE`。
- `Debug.xcconfig` / `Release.xcconfig`：切换 I/O 轨并注入编译条件
  （Debug = `EASYTIER_IO_FD`，Release = `EASYTIER_IO_PACKET_FLOW`；均含 `EASYTIER_FFI_LINKED`）。

#### `Shared/` — App 与 Extension 共用层（两个 target 都编译这份源码）

| 文件 | 职责 |
|------|------|
| `Models/AgentConfig.swift` | 设备配置（非秘密字段）模型 + 校验（schemaVersion/deviceId/CIDR/IPv4/relayPort/serverBaseURL）；扩展启动前必须通过校验 |
| `Models/AgentStatus.swift` | App 上报状态快照 + `AgentAppStatus` 语义枚举（online / connected / recoveryRequired / …） |
| `Models/TunnelStatus.swift` | Extension 状态快照（phase/virtualIP/peerCount/lastErrorCode/updatedAt）+ `TunnelPhase`；App 据此展示/上报真实隧道状态 |
| `Logging/RedactingLogger.swift` | 统一日志，输出前对 token/secret/注册码等敏感字段脱敏 |
| `Networking/AgentAPIClient.swift` | 平台 `/api/ios-agent/v1` 客户端：enroll / config / status / rotateToken；仅 HTTPS（开发允许 http://127.0.0.1） |
| `Security/SharedKeychain.swift` | 共享 Keychain，只存 `deviceToken` / `networkSecret` / `installationID`（AfterFirstUnlockThisDeviceOnly） |
| `Storage/AppGroupStore.swift` | App Group 非秘密配置/状态快照的原子读写（临时文件 + fsync + rename）；`clear()` 同时清配置与状态 |

#### `WhatsAppDeviceAgent/` — 主 App

| 文件 | 职责 |
|------|------|
| `WhatsAppDeviceAgentApp.swift` | App 入口 + `RootView`；scenePhase 控制前台心跳/后台停止；支持 `-reset-enrollment` 测试参数 |
| `AppModel.swift` | UI 状态协调（@MainActor）：注册流程、20s 心跳上报、VPN 启停、启动 VPN 后每 2s 轮询隧道状态同步界面 |
| `Enrollment/EnrollmentService.swift` | 注册流程：installationID 生成/恢复（Keychain 持久化）、enroll 调用、token/secret 入 Keychain、config 原子写入 App Group |
| `VPN/VPNManager.swift` | 保存唯一 VPN profile（`NETunnelProviderManager`）并启停；`providerConfiguration` 只放 schemaVersion/configVersion，不放秘密 |
| `Views/EnrollmentView.swift` | 注册引导页：扫码（大按钮）或手动输入服务器地址 + 注册码 |
| `Views/QRScannerView.swift` | 相机扫码（`AVCaptureSession` + 元数据输出），含相机权限请求与拒绝提示 |
| `Views/DeviceStatusView.swift` | 状态页：中央电源按钮启停 VPN + 连接状态卡片 + 重新注册菜单 |
| `Views/SettingsView.swift` | 设置页：设备信息、服务器/注册码修改并重新注册、关于 |
| `Info.plist` / `WhatsAppDeviceAgent.entitlements` | App 配置、相机权限文案、App Group / Keychain group |

#### `PacketTunnel/` — Network Extension（VPN 隧道）

| 文件 | 职责 |
|------|------|
| `PacketTunnelProvider.swift` | 隧道生命周期（fd 轨）：读配置/secret → 校验 → NE 设置（只路由 10.168.0.0/16）→ dup TUN fd → parse/run/set_tun_fd → 等 running+peer（30s）→ connected；stop/sleep/wake；每 15s 采集状态写 App Group |
| `EasyTierBridge.swift` | EasyTier C ABI 唯一入口（parse_config / run_network_instance / set_tun_fd / retain / collect_network_infos / get_error_msg / free_string），由 `#if EASYTIER_FFI_LINKED` 保护 |
| `EasyTierConfigBuilder.swift` | 结构化字段 → EasyTier TOML（instance/ipv4/网络身份/udp+tcp peer/flags/mtu），带转义与校验 |
| `TunnelFileDescriptor.swift` | 通过 packetFlow KVC 提取 TUN fd 并 dup（仅 fd 轨编译） |
| `PacketFlowBridge.swift` | App Store 轨（packetFlow）预留：未接入 FFI，调用即 `preconditionFailure`（M0-E） |
| `TunnelStatusReporter.swift` | 把隧道状态快照写入 App Group，供主 App 展示/上报（类型定义在 Shared） |
| `Info.plist` / `PacketTunnel.entitlements` | Extension 配置、Network Extension / App Group / Keychain 权限 |

#### 测试 target

| 目录 | 覆盖 |
|------|------|
| `WhatsAppDeviceAgentTests/` | AgentConfig 校验、EnrollmentService URL 校验、VPNManager profile 构造（`@testable import` 主 App） |
| `PacketTunnelTests/` | EasyTier TOML 构建与转义、TunnelStatus 快照 round-trip、FFI 链接断言（直接编译 Shared + PacketTunnel 源码） |
| `WhatsAppDeviceAgentUITests/` | 真实注册 HK 流程（注册码由运行脚本注入，占位符 `__ENROLL_CODE__` 时自动 skip） |

#### `Vendor/EasyTier/` — EasyTier FFI

- `include/easytier_ffi.h`：人工维护的 C ABI 声明（作为 PacketTunnel target 的 bridging header）。
- `SOURCE_COMMIT`：固定 fork 提交（v2.6.4-8428a89d），`scripts/build-easytier-ios.sh` 会核验克隆 HEAD 一致。
- `LICENSE-LGPL-3.0`：LGPL 许可占位。
- `EasyTierFFI.xcframework`：构建产物（gitignore，不入库），由 `scripts/build-easytier-ios.sh` 生成。

#### `scripts/` — 构建与核验

- `build-easytier-ios.sh`：核验固定 commit 与允许的 fork 文件 → Rust 1.95 构建 3 架构 → lipo 合并模拟器库 → `xcodebuild -create-xcframework` → 符号核验 → 输出 SHA-256。
- `verify-easytier-ffi-symbols.sh`：核验 xcframework 导出符号与头文件一致（基础 ABI 7 个必选 + packetFlow 3 个可选）。
- `easytier-fork-v2.6.4-8428a89d.patch`：EasyTier fork 最小修改（easytier-ffi / core / instance）。

#### `docs/` — 设计 / 测试 / 部署文档

- `design/`：方案可行性、主设计（6 章：架构/FFI/配置/安全/生命周期/接口）、方案评审。
- `testing/`：M0 里程碑测试记录、真机接入 HK 测试平台记录。
- `deployment/`：真机注册 SOP。

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

## 与平台对接接口

接口定义以平台主仓（whatsapp_ai）源码为准：`internal/handler/mobile_agent.go`（设备侧）、
`internal/handler/auth.go`（登录）、`internal/handler/mobile_devices.go`（管理端设备）、
`internal/handler/easytier.go`（easytier 运维），路由注册见 `cmd/server/main.go`。

### 后端地址

| 环境 | 后端地址 | 说明 |
|------|----------|------|
| 测试（HK） | `https://hk.hsddns.com` | iOS 注册页默认值；iOS 测试功能仅部署 HK |
| 生产 | `https://us.hsddns.com` | 不部署 iOS 测试功能（iOS 接口仅 HK 可用） |
| easytier relay | `hk.hsddns.com:11010`（UDP/TCP） | 组网服务端，虚拟网 `10.168.0.0/16` |

### 设备侧接口（App / Network Extension 直接调用）

前缀 `/api/ios-agent/v1`；除注册外均需 `Authorization: Bearer <deviceToken>`（token 只放 header，服务端存 SHA-256）。

| 方法 | 路径 | 用途 | 认证 | 说明 |
|------|------|------|------|------|
| POST | `/api/ios-agent/v1/enroll` | 注册 | 无 | 一次性租户注册码换 `deviceId` + `deviceToken` + 网络配置；`networkSecret`/`deviceToken` 仅本次响应明文，之后只存共享 Keychain |
| GET | `/api/ios-agent/v1/config` | 拉取配置 | Bearer | 只返回非秘密字段（`networkSecret` 为空，secret 仅在 enroll 下发） |
| POST | `/api/ios-agent/v1/status` | 心跳 / 状态上报 | Bearer | App 前台每 20 秒心跳；Extension 状态快照供平台判在线/离线（90s 超时窗口）；成功返回 204 |
| POST | `/api/ios-agent/v1/token/rotate` | token 轮换 | Bearer | ⚠️ iOS 侧 `AgentAPIClient.rotateToken` 已实现，但主仓 `mobile_agent.go` **尚未注册该路由，当前调用返回 404**，契约待主仓补齐或 iOS 侧移除 |

**enroll 请求**（`EnrollRequest` / 主仓 `MobileEnrollRequest`）：

```json
{
  "enrollmentCode": "9C4K-7Q2M-P8RX-H5TW",
  "installationId": "<Keychain 持久化的设备唯一 ID>",
  "appVersion": "1.0",
  "osVersion": "18.5",
  "deviceModel": "iPhone",
  "locale": "zh_CN",
  "platform": "ios"
}
```

**enroll 成功响应**（`EnrollResponse`，HTTP 201）：

```json
{
  "deviceId": "abcdefghijklmnopqrstuvwx",
  "deviceToken": "<明文 token，仅本次>",
  "config": {
    "schemaVersion": 1,
    "configVersion": 1,
    "networkName": "wa-ios",
    "networkCIDR": "10.168.0.0/16",
    "iphoneIPv4": "10.168.1.5",
    "relayHost": "hk.hsddns.com",
    "relayPort": 11010,
    "networkSecret": "<明文 secret，仅本次>"
  }
}
```

**enroll 失败**：注册码不存在/过期/已消费/设备不可注册 → HTTP 401，`{"error":{"code":"IOS_ENROLLMENT_INVALID","message":"注册码无效或已过期，请联系管理员重新签发。"}}`

**status 请求**（`AgentStatus` / 主仓 `MobileStatusReport`）：

```json
{
  "appStatus": "online",
  "vpnPhase": "connected",
  "virtualIP": "10.168.1.5",
  "peerCount": 1,
  "lastErrorCode": null
}
```

### 平台管理端接口（Web 控制台）

管理端走 session 认证（邮箱+密码登录后 Set-Cookie `session_id`，后续请求带 CSRF），与设备侧 Bearer 相互独立。

**登录（用户明确要求列出）**：

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/auth/login` | 登录：`{"email":"...","password":"..."}` → 204 + Set-Cookie `session_id`；失败 401 `AUTH_INVALID`，连续失败限流（5 次/15 分钟锁 15 分钟） |
| POST | `/api/auth/logout` | 退出登录（需 session + CSRF） |
| GET | `/api/auth/me` | 当前会话信息（需 session + CSRF） |

**设备管理**（`/api/ios-devices`，iOS 先行、兼容 Android）：

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/ios-devices` | 当前租户设备列表（含 easytier 组网状态 `networkingConnected`） |
| POST | `/api/ios-devices/enrollment-code` | 生成/刷新租户级一次性注册码（201 `{"enrollmentCode":"..."}`） |
| GET | `/api/ios-devices/:id/events` | 设备操作/状态事件日志 |
| PATCH | `/api/ios-devices/:id` | 补录/更新设备（如 name） |

**easytier 服务端运维**（`/api/easytier`，属平台侧，不在本仓库实现）：

| 方法 | 路径 | 权限 | 说明 |
|------|------|------|------|
| GET | `/api/easytier/status` | `ios_devices:view` | 组网服务端状态 |
| GET | `/api/easytier/config` | `ios_devices:view` | 当前配置查看 |
| POST | `/api/easytier/action` | `ios_devices:update` | 启停等运维动作 |
| PUT | `/api/easytier/config` | `ios_devices:update` | 配置修改 |

### 契约差异（已确认）

- `POST /api/ios-agent/v1/token/rotate`：iOS 侧已实现调用，主仓未注册路由 → 当前 404，待对齐。
- `status` 上报：iOS 侧额外携带 `extensionUpdatedAt` 字段，主仓 `MobileStatusReport` 未声明，解码时忽略，不影响。
