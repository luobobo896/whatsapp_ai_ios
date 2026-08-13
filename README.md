# WhatsAppDeviceAgent（iOS 设备 agent）

本目录即独立仓库 `whatsapp_ai_ios` 的根目录。设备侧 agent 已并入 WDA
（Appium WebDriverAgent v16.1.5 fork，纯 Objective-C）：WDA 启动时自动向平台
`/api/ios-agent/v1` 注册、20s 心跳、WSS 长连接；数据面 = 平台经 easytier
子网路由直连 WDA（`http://<手机局域网IP>:8100`）。无 VPN、无独立 App。

## 架构

- agent 以 Objective-C 集成进 `WebDriverAgentRunner`：
  `WDAgent`（协调器）+ `WDAgentClient`（enroll / 20s 心跳 / WSS，token 存 Keychain）。
- 注册配置由 `scripts/start-wda.sh` 注入（xctestrun `EnvironmentVariables`，
  因为 `xcodebuild test` 不透传 shell 环境变量）：`WDA_ENROLL_CODE`（必填）、
  `WDA_PLATFORM_URL`（默认 `https://hk.hsddns.com`）。
- 平台契约：`/api/ios-agent/v1`（enroll / config / status / ws），默认 `https://hk.hsddns.com`。
- **控制面 / 数据面分离**：设备 agent 只做「注册 + 心跳 + WSS」（控制面）；群发任务**不走 WSS**，
  由平台侧 controller 经 easytier 子网路由**直连** `http://<手机局域网IP>:8100`（数据面）发 WebDriver 指令操作 WhatsApp。

### 执行模型（谁执行 / 媒介是什么）

- **谁执行**：`wda_whatsapp_broadcast.py`（参考实现）/ 平台 Go controller 跑在**平台那台机器**上，
  不跑在手机上。手机只跑 WDA（监听 8100 的 HTTP 服务器），被动接受指令。
- **媒介**：网络（Wi-Fi / 局域网，HTTP over TCP）到 `http://<手机IP>:8100`。**不是 USB 数据线**。
- **数据线边界**：USB 仅在「首次启动 WDA」用一次（Mac + Xcode 拉起 XCTest 会话）；WDA 起来后即可拔线，
  后续群发全靠 Wi-Fi 网络。
- **平台下发 ≠ 推给手机执行**：平台自己拿任务（text + phones），逐条 HTTP 调手机 8100 驱动 WhatsApp。

## 仓库结构

```text
scripts/                         WDA 启动（start-wda.sh）与 WhatsApp 群发（wda_whatsapp_broadcast.py）
WebDriverAgentRunner/            WDA 入口 + 设备 agent（WDAgent / WDAgentClient）
WebDriverAgentLib/               WDA 核心库（Appium v16.1.5 fork）
WebDriverAgent.xcodeproj/        Xcode 工程
docs/                            设计文档
```

### WebDriverAgent — WDA + 设备 agent

| 文件 | 职责 |
|------|------|
| `WebDriverAgentRunner/WDAgent.h/m` | agent 协调器：读环境变量、installationId 持久化（NSUserDefaults）、WDA 地址（局域网 IP + USE_PORT） |
| `WebDriverAgentRunner/WDAgentClient.h/m` | 网络层：enroll（token 存 Keychain）、20s 心跳 `/status`、WSS 长连接（hello/heartbeat/ack、退避重连） |
| `WebDriverAgentRunner/UITestingUITests.m` | WDA 入口 `testRunner`；`+setUp` 检测 `WDA_ENROLL_CODE` 后启动 agent（未配置则 WDA 纯净） |

### scripts/

| 文件 | 职责 |
|------|------|
| `start-wda.sh` | 启动 WDA + agent（真机前台常驻，Ctrl-C 停止）；配置注册码时 build-for-testing → xctestrun 注入 → test-without-building |
| `wda_client.py` | 通用 WDA HTTP 客户端（会话/元素/输入/发送/截图/深链），供群发脚本复用 |
| `wda_whatsapp_broadcast.py` | WhatsApp 群发主链路：text+phones → 深链开会话 → 发送 → 结构化报告 |

## 快速使用

```bash
WDA_TEAM=<Apple Team ID> WDA_ENROLL_CODE=<平台注册码> \
./scripts/start-wda.sh --udid <UDID>
```

- `WDA_TEAM`：**必填**（真机签名用的 Apple Team ID）。
- `WDA_ENROLL_CODE`：平台生成的一次性注册码；**不设置则 WDA 保持纯净**（只跑 UI 自动化，不注册平台）。
- `WDA_PLATFORM_URL`：可选，默认 `https://hk.hsddns.com`。
- 启动后 `curl http://<手机IP>:8100/status` 返回 `"ready": true` 即 WDA 就绪；
  agent 注册成功后平台设备列表出现该设备（在线判定依赖 20s 心跳）。

## 构建验证

```bash
xcodebuild -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner -destination 'generic/platform=iOS Simulator' build
```

## 文档

- 设计：`docs/design/ios-whatsapp-agent-design.md`（设备 agent + 平台契约 + 群发业务待实现设计）

## WDA 自动化操作手册（真机）

### 1. 原理与边界

- **WDA 是什么**：Appium 开源的 WebDriverAgent（XCTest UI 自动化服务），已 vendored 进本仓库
  WebDriverAgent 工程（v16.1.5 fork），是仓库的一部分，不是外部依赖。
- **为什么必须 Mac 侧启动**：iOS 系统限制，普通 App 没有安装/签名/启动 XCTest runner 的权限。
  WDA 只能由 Mac 侧 `xcodebuild test` 以 XCTest 会话方式拉起，
  **进程常驻 = WDA 服务存活**，Ctrl-C 即停止。
- **访问方式**：`http://<手机局域网IP>:8100`（W3C WebDriver 协议）。agent 的 wdaUrl
  由 `WDAgent.lanIPv4Address` 生成（en0 Wi-Fi 优先），随 `/status` 心跳上报平台，平台据此直连。

### 2. 前置条件

| 项 | 要求 |
|---|---|
| Mac | Xcode 26.x；**Xcode SDK 版本 ≥ 手机 iOS 版本**（设备系统比 SDK 新会导致 XCTest 会话失败） |
| Apple ID | 付费开发者账号（免费 7 天签名不满足长期运行；VPN/Network Extension 已移除，无额外 entitlement） |
| iPhone | 开启开发者模式、解锁、屏幕常亮；与 Mac 同一 Wi-Fi；已登录 WhatsApp（对应手机号） |
| 首次 | USB 连接并信任电脑；设置 → 通用 → VPN 与设备管理 → 信任开发者证书 |
| 网络 | 首次授予「本地网络」权限：设置 → 隐私与安全性 → 本地网络 → 打开 WebDriverAgentRunner |

### 3. 启动 WDA 服务器（自研入口）

```bash
./scripts/start-wda.sh                        # 自动探测第一台 iPhone 并启动
./scripts/start-wda.sh --udid <UDID>          # 指定设备
./scripts/start-wda.sh --identity <SHA1>      # 钥匙串有重复证书时，指定 profile 引用的签名身份
```

- 参数优先级：命令行 > 环境变量（`WDA_UDID` / `WDA_TEAM` / `WDA_SIGN_IDENTITY`）> 自动探测。
- `WDA_TEAM` 必填（真机签名用的 Apple Team ID）。
- 脚本不把机器相关的 UDID/Team/证书写进仓库，全部本地签名配置。
- 启动后**前台常驻**：`curl http://<手机IP>:8100/status` 返回 `"ready": true` 即成功。

等价原始命令（脚本内部就是它）：

```bash
xcodebuild -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner -destination 'id=<UDID>' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<Team> CODE_SIGN_STYLE=Automatic \
  [EXPANDED_CODE_SIGN_IDENTITY=<SHA1>] test
```

### 4. 自动发送消息

#### 4.1 WhatsApp 群发（主链路）

真机先做预检（不发送，只确认 WDA 就绪 + WhatsApp 可拉起）：

```bash
python3 scripts/wda_whatsapp_broadcast.py --wda http://<手机IP>:8100 --check
```

预检通过后发送：

```bash
# 命令行直接给手机号
python3 scripts/wda_whatsapp_broadcast.py \
  --wda http://<手机IP>:8100 \
  --text "某商品价格实惠，现在只要100元即可" \
  --phones 18078526388,17688540775

# 平台 payload（JSON，支持 stdin）
echo '{"text":"某商品价格实惠，现在只要100元即可","phones":["18078526388","17688540775"]}' \
  | python3 scripts/wda_whatsapp_broadcast.py --wda http://<手机IP>:8100 --payload -
```

执行流程（每步回读校验）：

1. **手机号 → E.164**：`18078526388` → `8618078526388`（`--country-code` 默认 86）。
2. **开会话**：WDA `/url` 打开 `whatsapp://send?phone=<e164>&text=<urlencoded>`，
   自动进入对应手机号的 WhatsApp 会话并预填文本，无需搜索联系人。
3. **输入**：回读输入框文本，不一致才重写；点发送（`--send-labels Send,发送` 多 label 候选，找不到用像素定位兜底）。
4. **校验**：发送后输入框清空判定成功；单条失败不阻断整批。
5. **上报**：输出结构化报告（stdout JSON，可用 `--out report.json` 落盘），
   `summary` 含 `total/sent/failed/durationMs/avgPerItemMs`，
   `items[]` 逐条含 `phone/e164/status/durationMs/attempts/error/steps[]`（执行步骤日志）；
   `failed > 0` 时退出码 1，便于平台判定整批是否成功。

**报告结构**（平台分析/优化用）：

```json
{
  "meta": {"wda": "http://<手机IP>:8100", "bundleId": "net.whatsapp.WhatsApp",
           "startedAt": "...", "endedAt": "...", "durationMs": 15234},
  "summary": {"total": 2, "sent": 1, "failed": 1,
              "durationMs": 15234, "avgPerItemMs": 7617},
  "items": [
    {"phone": "18078526388", "e164": "8618078526388", "status": "sent",
     "durationMs": 7312, "attempts": 1, "error": null,
     "steps": [
       {"step": "ensure_session", "ms": 120, "t": "..."},
       {"step": "open_chat", "ms": 3200, "t": "..."},
       {"step": "send_tapped", "ms": 1800, "t": "..."},
       {"step": "sent_verified", "ms": 200, "t": "..."}
     ]}
  ]
}
```

优化点（相对手工 curl）：

- 全程 `POST /element` 谓词定向查询，**不 `GET /source` 全量 dump 元素树**；
- 每步元素级定位 + 回读校验，不盲点；
- 会话复用（`--session-id`）；会话失效自动重建重试（`--max-retry`，默认 1 次）。

### 5. 常见问题排查（实测踩坑）

| 现象 | 原因 | 解决 |
|---|---|---|
| `requires a development team` | WDA 工程未配置 Team | 用 `start-wda.sh` 并设置 `WDA_TEAM=<Team ID>` |
| 签名 `ambiguous (matches ...)` | 钥匙串存在同名重复开发证书 | `security find-identity -p codesigning -v` 找出 profile 引用的证书，`--identity <SHA1>`；根治：删除重复证书 |
| 安装报 `无法验证其完整性` | 重签身份与 profile 证书不一致 | `--identity` 必须用 profile 引用的那个证书 |
| Runner 起来 ~18s 后 `IDE disconnection` / exit 74 | 手机 iOS 版本比 Xcode SDK 新（如 iOS 26.6 beta vs Xcode 26.3/SDK 26.2） | 升级 Xcode 或换 iOS ≤ SDK 的真机/模拟器 |
| ping 通但 `curl :8100` 超时 | iOS「本地网络」权限未授权 | 设置 → 隐私与安全性 → 本地网络 → 允许 WebDriverAgentRunner |
| 换 Wi-Fi 后 8100 不通 | WDA 绑定在启动时的旧 IP | 重启 WDA（重跑 `start-wda.sh`） |
| 元素点击「发送」无反应 | iOS 18 键盘 frame 偏移 | 发送脚本已用像素聚类兜底 |
| 关 App 再开闪退/操作失败 | WDA 会话指向已终止的 App | 发送脚本自动重建会话重试 |

### 6. agent 与 WDA 的关系

- 设备 agent 已并入 WDA Runner（`WDAgent`/`WDAgentClient`），**WDA 启动即注册/心跳/WSS**，没有独立 App。
- agent 上报 `wdaUrl`（`http://<局域网IP>:8100`）给平台，平台据此直连 WDA 驱动目标 App。

## 与平台对接接口

接口定义以平台主仓（whatsapp_ai）源码为准：`internal/handler/mobile_agent.go`（设备侧）、
`internal/handler/auth.go`（登录）、`internal/handler/mobile_devices.go`（管理端设备）、
`internal/handler/easytier.go`（easytier 组网，Go RPC），路由注册见 `cmd/server/main.go`。

### 后端地址

| 环境 | 后端地址 | 说明 |
|------|----------|------|
| 测试（HK） | `https://hk.hsddns.com` | iOS 注册页默认值；iOS 测试功能仅部署 HK |
| 生产 | `https://us.hsddns.com` | 不部署 iOS 测试功能（iOS 接口仅 HK 可用） |

### 设备侧接口（agent 调用）

前缀 `/api/ios-agent/v1`；除注册外均需 `Authorization: Bearer <deviceToken>`（token 只放 header，服务端存 SHA-256）。

| 方法 | 路径 | 用途 | 认证 | 说明 |
|------|------|------|------|------|
| POST | `/api/ios-agent/v1/enroll` | 注册 | 无 | 一次性租户注册码换 `deviceId` + `deviceToken` + 配置；`deviceToken` 仅本次响应明文、之后存 Keychain；`networkSecret` 已不使用 |
| GET | `/api/ios-agent/v1/config` | 拉取配置 | Bearer | 只返回非秘密字段（`networkSecret` 为空，secret 仅在 enroll 下发） |
| POST | `/api/ios-agent/v1/status` | 心跳 / 状态上报 | Bearer | 设备 agent 每 20 秒心跳（90s 超时窗口判离线）；隧道相关字段固定中性值；成功返回 204 |
| POST | `/api/ios-agent/v1/token/rotate` | token 轮换 | Bearer | ⚠️ 当前设备侧未实现 token 轮换，主仓 `mobile_agent.go` 也未注册该路由（调用返回 404）；契约待主仓补齐或两端移除 |
| GET upgrade | `/api/ios-agent/v1/ws` | WSS 长连接 | Bearer | 设备 agent 建立长连接、每 20s `agent:heartbeat`；server 可下发 `server:config_changed` / `server:diagnostic_request`；关闭码 4001 token 无效 / 4002 被替换 / 4003 设备禁用 / 4004 协议非法（设备端对 4001–4004 停止重连）。群发 `task:dispatch` 不在此协议 |

**enroll 请求**（`EnrollRequest` / 主仓 `MobileEnrollRequest`）：

```json
{
  "enrollmentCode": "9C4K-7Q2M-P8RX-H5TW",
  "installationId": "<NSUserDefaults 持久化的设备唯一 ID>",
  "deviceUdids": ["<从 embedded.mobileprovision 解析的 UDID 列表>"],
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

**登录**：

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

**easytier 组网**：属平台侧，不在本仓库实现；平台主仓已用 Go RPC 直接控制 easytier（不再用 `easytier-cli` CLI）。

### 契约差异（已确认）

- `POST /api/ios-agent/v1/token/rotate`：设备侧未实现 token 轮换，主仓也未注册该路由（当前 404）。
- `status` 上报：VPN/组网已移除，`vpnPhase`/`virtualIP`/`peerCount` 上报固定中性值（`stopped`/`null`/`0`）。
- `WSS /api/ios-agent/v1/ws`：**设备侧 `WDAgentClient` 已实现**（20s heartbeat、config_changed/diagnostic_request 处理、close code 4001–4004 停止重连、退避重连）；**主仓 `ws.go` 未落地**，当前连接会被拒绝/无推送，需主仓实现服务端。
