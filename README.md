# WhatsAppDeviceAgent（iOS 工程）

本目录即独立仓库 `whatsapp_ai_ios`（由 whatsapp_ai 主仓迁移而来）的根目录，
`.git` / README / docs / scripts / .gitignore 全部收敛于此。
iPhone App 通过平台 `/api/ios-agent/v1` 接口完成注册/配置下发/心跳/状态上报。
> 注：easytier 与 VPN（Network Extension）已整体移除，数据面改为 WDA 局域网直连（`http://<局域网IP>:8100`），App 不再需要开启 VPN。
与平台主仓（whatsapp_ai）的接口契约：`/api/ios-agent/v1`（enroll / config / status / token/rotate），
平台地址默认 `https://hk.hsddns.com`（注册页可改）。
（工程基于 `docs/design/2026-08-06-ios-whatsapp-broadcast-vpn.md` 第 6 章搭建。）

## 仓库结构（设计 6.1）

```text
WhatsAppDeviceAgent.xcodeproj    Xcode 工程（App + 2 个测试 target）
Configs/                        Base/Debug/Release.xcconfig（统一 bundle 前缀、iOS 15.0）
WhatsAppDeviceAgent/             主 App（含原 Shared 共用层）：注册、状态页、WDA 直连地址展示、模型/Keychain/App Group/API 客户端/脱敏日志
WhatsAppDeviceAgentTests/        主 App 单元测试
WhatsAppDeviceAgentUITests/      UI 测试（真实注册 HK 平台）
scripts/                        WDA 启动（start-wda.sh）与微信自动发送（wda_send.py）脚本
third_party/WebDriverAgent/      已入库的 WDA v16.1.5（XCTest UI 自动化服务，真机由脚本拉起）
docs/                           设计 / 测试 / 部署文档
```

### 各模块职责

#### `Configs/` — 构建设置（xcconfig）

- `Base.xcconfig`：统一部署目标 iOS 15.0、Swift 5.0、bundle 前缀
  （`APP_BUNDLE_ID` / `APP_GROUP_ID` / `KEYCHAIN_GROUP_ID`）。
- `Debug.xcconfig` / `Release.xcconfig`：仅引入 `Base.xcconfig`。

#### `WhatsAppDeviceAgent/` — 主 App

| 文件 | 职责 |
|------|------|
| `WhatsAppDeviceAgentApp.swift` | App 入口 + `RootView`；scenePhase 控制前台心跳/后台停止；支持 `-reset-enrollment` 测试参数 |
| `AppModel.swift` | UI 状态协调（@MainActor）：注册流程、20s 心跳上报、WDA 直连地址上报 |
| `Enrollment/EnrollmentService.swift` | 注册流程：installationID 生成/恢复（Keychain 持久化）、enroll 调用、token/secret 入 Keychain、config 原子写入 App Group |
| `Views/EnrollmentView.swift` | 注册引导页：扫码（大按钮）或手动输入服务器地址 + 注册码 |
| `Views/QRScannerView.swift` | 相机扫码（`AVCaptureSession` + 元数据输出），含相机权限请求与拒绝提示 |
| `Views/DeviceStatusView.swift` | 状态页：在线状态卡片（WDA 地址 / 设备信息）+ 重新注册菜单 |
| `Views/SettingsView.swift` | 设置页：设备信息、服务器/注册码修改并重新注册、关于 |
| `Models/AgentConfig.swift` | 设备配置（非秘密字段）模型 + 校验（schemaVersion/deviceId/CIDR/IPv4/relayPort/serverBaseURL）；注册配置必须通过校验 |
| `Models/AgentStatus.swift` | App 上报状态快照 + `AgentAppStatus` 语义枚举（online / connected / recoveryRequired / …） |
| `Logging/RedactingLogger.swift` | 统一日志，输出前对 token/secret/注册码等敏感字段脱敏 |
| `Networking/AgentAPIClient.swift` | 平台 `/api/ios-agent/v1` 客户端：enroll / config / status / rotateToken；仅 HTTPS（开发允许 http://127.0.0.1） |
| `Security/SharedKeychain.swift` | 共享 Keychain，只存 `deviceToken` / `networkSecret` / `installationID`（AfterFirstUnlockThisDeviceOnly） |
| `Storage/AppGroupStore.swift` | App Group 非秘密配置的原子读写（临时文件 + fsync + rename）；`clear()` 同时清配置与历史隧道状态 |
| `Info.plist` / `WhatsAppDeviceAgent.entitlements` | App 配置、相机权限文案、App Group / Keychain group |


#### 测试 target

| 目录 | 覆盖 |
|------|------|
| `WhatsAppDeviceAgentTests/` | AgentConfig 校验、EnrollmentService URL 校验（`@testable import` 主 App） |
| `WhatsAppDeviceAgentUITests/` | 真实注册 HK 流程（注册码由运行脚本注入，占位符 `__ENROLL_CODE__` 时自动 skip） |


#### `scripts/` — 构建与核验

| 文件 | 职责 |
|------|------|
| `start-wda.sh` | 启动 WDA 服务器（真机前台常驻，Ctrl-C 停止）：自动探测 iPhone、读取主工程 Team、处理重复证书，封装为自研入口，避免手敲 third_party 命令 |
| `wda_send.py` | WDA 微信自动发送：全程谓词定位（不 dump 元素树）、每步回读校验、发送键像素聚类定位（iOS18 键盘 frame 偏移兜底）、会话失效自动重建 |

```bash
./scripts/start-wda.sh --udid <UDID>            # 启动 WDA
python3 scripts/wda_send.py --wda http://<手机IP>:8100 \
  --contact "迪迦Hanson" --text "你好"          # 自动发送
```

#### `docs/` — 设计 / 测试 / 部署文档

- `design/`：方案可行性、主设计（6 章：架构/FFI/配置/安全/生命周期/接口）、方案评审。
- `testing/`：M0 里程碑测试记录、真机接入 HK 测试平台记录。
- `deployment/`：真机注册 SOP。

## 打开与运行

1. 打开 `WhatsAppDeviceAgent.xcodeproj`（需要 Xcode 16+）。
2. Scheme 选 `WhatsAppDeviceAgent`，选择模拟器或真机运行。
   - 模拟器：直接 Run，注册用手动输入注册码（模拟器无摄像头）。
   - 真机：Signing 填 Apple Team、iPhone 开启开发者模式；已移除 Network Extension，免费 Apple ID 即可签名。
     更换 bundle 前缀时，App/App Group/Keychain group 必须成组修改（设计 6.1）。


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
  （easytier 相关测试文档已随组件移除）
- 部署：`docs/deployment/ios-device-enroll-test-sop.md`

## WDA 自动化操作手册（真机）

### 1. 原理与边界

- **WDA 是什么**：Appium 开源的 WebDriverAgent（XCTest UI 自动化服务），已 vendored 进本仓库
  `third_party/WebDriverAgent`（v16.1.5，提交 `186f5d1`），是仓库的一部分，不是外部依赖。
- **为什么必须 Mac 侧启动**：iOS 系统限制，普通 App 没有安装/签名/启动 XCTest runner 的权限
  （设计 §1.4/§8.3）。WDA 只能由 Mac 侧 `xcodebuild test` 以 XCTest 会话方式拉起，
  **进程常驻 = WDA 服务存活**，Ctrl-C 即停止。
- **访问方式**：`http://<手机WiFiIP>:8100`（W3C WebDriver 协议）。App 状态页的 wdaUrl
  由 `DeviceNetwork.lanIPv4()` 生成（en0 Wi-Fi 优先），上报平台后平台据此直连。

### 2. 前置条件

| 项 | 要求 |
|---|---|
| Mac | Xcode 26.x；**Xcode SDK 版本 ≥ 手机 iOS 版本**（设备系统比 SDK 新会导致 XCTest 会话失败） |
| Apple ID | 付费开发者账号（免费 7 天签名不满足长期运行；VPN/Network Extension 已移除，无额外 entitlement） |
| iPhone | 开启开发者模式、解锁、屏幕常亮；与 Mac 同一 Wi-Fi；目标 App（微信等）已登录 |
| 首次 | USB 连接并信任电脑；设置 → 通用 → VPN 与设备管理 → 信任开发者证书 |
| 网络 | 首次授予「本地网络」权限：设置 → 隐私与安全性 → 本地网络 → 打开 WebDriverAgentRunner |

### 3. 启动 WDA 服务器（自研入口）

```bash
./scripts/start-wda.sh                        # 自动探测第一台 iPhone 并启动
./scripts/start-wda.sh --udid <UDID>          # 指定设备
./scripts/start-wda.sh --identity <SHA1>      # 钥匙串有重复证书时，指定 profile 引用的签名身份
```

- 参数优先级：命令行 > 环境变量（`WDA_UDID` / `WDA_TEAM` / `WDA_SIGN_IDENTITY`）> 自动探测。
- Team 默认从主工程 `project.pbxproj` 的 `DEVELOPMENT_TEAM` 读取，无需手填。
- 脚本不把机器相关的 UDID/Team/证书写进仓库（设计 §8.2 要求本地签名配置）。
- 启动后**前台常驻**：`curl http://<手机IP>:8100/status` 返回 `"ready": true` 即成功。

等价原始命令（脚本内部就是它）：

```bash
xcodebuild -project third_party/WebDriverAgent/WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner -destination 'id=<UDID>' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<Team> CODE_SIGN_STYLE=Automatic \
  [EXPANDED_CODE_SIGN_IDENTITY=<SHA1>] test
```

### 4. 自动发送微信消息

```bash
python3 scripts/wda_send.py --wda http://192.168.20.235:8100 \
  --contact "迪迦Hanson" --text "你好" [--session-id XXX] [--verbose]
```

执行流程（每步回读校验）：

1. **会话**：探测 WDA 会话有效性；App 被关/会话失效时自动 `DELETE` 旧会话并重建（重新拉起微信），
   避免「关掉 App 再开」后陈旧会话导致的失败与闪退。
2. **进会话**：谓词 `Cell CONTAINS '<联系人>'` 直接点；列表没有则走搜索框输入并点结果。
3. **输入**：点击输入框 → `value` 写入 → 回读 `/element/:id/text` 校验等于目标文本。
4. **发送**：优先元素点击；iOS 18 下 WDA 键盘 frame 整体偏移时，用截图+像素聚类定位发送键真实坐标点击。
5. **校验**：发送后输入框清空才算成功。

优化点（相对手工 curl）：

- 全程 `POST /element` 谓词定向查询，**不 `GET /source` 全量 dump 元素树**（微信树 ~460KB，一次约 20s，是慢的主因）；
- 每步元素级定位 + 回读校验，不盲点；
- 会话复用（`--session-id`），避免每次冷启动微信；
- 会话失效自动重建重试（`--max-retry`，默认 1 次）。

### 5. 常见问题排查（实测踩坑）

| 现象 | 原因 | 解决 |
|---|---|---|
| `requires a development team` | WDA 工程未配置 Team | 用 `start-wda.sh`（自动读取主工程 Team） |
| 签名 `ambiguous (matches ...)` | 钥匙串存在同名重复开发证书 | `security find-identity -p codesigning -v` 找出 profile 引用的证书，`--identity <SHA1>`；根治：删除重复证书 |
| 安装报 `无法验证其完整性` | 重签身份与 profile 证书不一致 | `--identity` 必须用 profile 引用的那个证书 |
| Runner 起来 ~18s 后 `IDE disconnection` / exit 74 | 手机 iOS 版本比 Xcode SDK 新（如 iOS 26.6 beta vs Xcode 26.3/SDK 26.2） | 升级 Xcode 或换 iOS ≤ SDK 的真机/模拟器 |
| ping 通但 `curl :8100` 超时 | iOS「本地网络」权限未授权 | 设置 → 隐私与安全性 → 本地网络 → 允许 WebDriverAgentRunner |
| 换 Wi-Fi 后 8100 不通 | WDA 绑定在启动时的旧 IP | 重启 WDA（重跑 `start-wda.sh`） |
| 元素点击「发送」无反应 | iOS 18 键盘 frame 偏移 | `wda_send.py` 已用像素聚类兜底 |
| 关 App 再开闪退/操作失败 | WDA 会话指向已终止的 App | `wda_send.py` 自动重建会话重试 |

### 6. 与主 App 的关系

- 主 App 只负责注册/心跳/上报 `wdaUrl`，**不启动 WDA**；WDA 由 Mac 侧脚本独立拉起。
- 平台通过 App 上报的 `wdaUrl`（`http://<局域网IP>:8100`）直连 WDA 驱动目标 App。

## 与平台对接接口

接口定义以平台主仓（whatsapp_ai）源码为准：`internal/handler/mobile_agent.go`（设备侧）、
`internal/handler/auth.go`（登录）、`internal/handler/mobile_devices.go`（管理端设备）、
`internal/handler/easytier.go`（easytier 运维），路由注册见 `cmd/server/main.go`。

### 后端地址

| 环境 | 后端地址 | 说明 |
|------|----------|------|
| 测试（HK） | `https://hk.hsddns.com` | iOS 注册页默认值；iOS 测试功能仅部署 HK |
| 生产 | `https://us.hsddns.com` | 不部署 iOS 测试功能（iOS 接口仅 HK 可用） |
| easytier relay | `hk.hsddns.com:11010`（UDP/TCP） | 平台侧组网服务端（App 已移除数据面，不再直连） |

### 设备侧接口（App 直接调用）

前缀 `/api/ios-agent/v1`；除注册外均需 `Authorization: Bearer <deviceToken>`（token 只放 header，服务端存 SHA-256）。

| 方法 | 路径 | 用途 | 认证 | 说明 |
|------|------|------|------|------|
| POST | `/api/ios-agent/v1/enroll` | 注册 | 无 | 一次性租户注册码换 `deviceId` + `deviceToken` + 网络配置；`networkSecret`/`deviceToken` 仅本次响应明文，之后只存共享 Keychain |
| GET | `/api/ios-agent/v1/config` | 拉取配置 | Bearer | 只返回非秘密字段（`networkSecret` 为空，secret 仅在 enroll 下发） |
| POST | `/api/ios-agent/v1/status` | 心跳 / 状态上报 | Bearer | App 前台每 20 秒心跳（90s 超时窗口判离线）；隧道相关字段固定中性值；成功返回 204 |
| POST | `/api/ios-agent/v1/token/rotate` | token 轮换 | Bearer | ⚠️ iOS 侧 `AgentAPIClient.rotateToken` 已实现，但主仓 `mobile_agent.go` **尚未注册该路由，当前调用返回 404**，契约待主仓补齐或 iOS 侧移除 |
| GET upgrade | `/api/ios-agent/v1/ws` | WSS 长连接（设计 §6.8/§7.3） | Bearer | App 前台连接、每 20s `agent:heartbeat`，后台发 `app:suspended` 后断开；server 可下发 `server:config_changed` / `server:diagnostic_request`；关闭码 4001 token 无效 / 4002 被替换 / 4003 设备禁用 / 4004 协议非法。群发 `task:dispatch` 不在此协议 |

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
  "vpnPhase": "stopped",
  "virtualIP": null,
  "peerCount": 0,
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
- `status` 上报：VPN/组网已移除，`vpnPhase` 固定 `stopped`、`virtualIP` 为 null、`peerCount` 为 0；`extensionUpdatedAt` 等隧道字段主仓未声明，解码时忽略，不影响。
- `WSS /api/ios-agent/v1/ws`：**App 侧 `AgentWebSocket` 客户端已实现**（前台连接、20s heartbeat、后台 suspended、config_changed/diagnostic_request 处理、close code 4001/4003 处理、退避重连）；**主仓 `ws.go` 未落地**，当前连接会被拒绝/无推送，需主仓按 §7.2/§7.3 实现服务端。
