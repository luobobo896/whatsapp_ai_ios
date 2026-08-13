# iOS WhatsApp 设备 Agent 设计（当前版）

> 日期：2026-08-13（`rebuild/from-scratch` 分支整理）
> 状态：**设备 agent（注册/心跳/WSS）已实现**；**WhatsApp 群发核心业务待实现**。
> 本文取代早期 `2026-08-06-ios-whatsapp-broadcast-vpn.md`（VPN/easytier 组网架构已整体移除）。

## 1. 当前架构（已实现）

设备侧 agent 已并入 WDA（Appium WebDriverAgent v16.1.5 fork，纯 Objective-C）：

| 文件 | 职责 |
|---|---|
| `WebDriverAgentRunner/WDAgent.m/h` | 协调器：读环境变量、`installationId` 持久化、WDA 地址（局域网 IP + USE_PORT） |
| `WebDriverAgentRunner/WDAgentClient.m/h` | 网络层：enroll / 20s 心跳 `/status` / WSS 长连接（hello/heartbeat/ack、退避重连、关闭码处理） |
| `WebDriverAgentRunner/UITestingUITests.m` | WDA 入口 `testRunner`；`+setUp` 检测 `WDA_ENROLL_CODE` 后启动 agent（未配置则 WDA 纯净） |
| `scripts/start-wda.sh` | 启动 WDA + agent；build-for-testing → 注入环境变量 → test-without-building |
| `scripts/wda_send.py` | WDA 微信自动发送（谓词定位 + 回读校验 + 会话重建） |

数据面 = 平台经 easytier 子网路由直连 WDA（`http://<手机局域网IP>:8100`）。无 VPN、无独立 App。

## 2. 平台契约（`/api/ios-agent/v1`）

前缀 `/api/ios-agent/v1`；除注册外均需 `Authorization: Bearer <deviceToken>`（token 只放 header，服务端存 SHA-256）。

| 方法 | 路径 | 用途 | 认证 |
|---|---|---|---|
| POST | `/enroll` | 一次性租户注册码换 `deviceId` + `deviceToken` + 配置 | 无 |
| GET | `/config` | 拉取当前配置（非秘密字段） | Bearer |
| POST | `/status` | 心跳/状态上报（前台每 20s，90s 超时窗口判离线） | Bearer |
| GET upgrade | `/ws` | WSS 长连接（hello/heartbeat/ack，服务端可下发 config_changed / diagnostic_request） | Bearer |

**enroll 请求**：

```json
{
  "enrollmentCode": "9C4K-7Q2M-P8RX-H5TW",
  "installationId": "<持久化的设备唯一 ID>",
  "appVersion": "1.0",
  "osVersion": "18.5",
  "deviceModel": "iPhone",
  "locale": "zh_CN",
  "platform": "ios",
  "deviceUdids": ["<从 embedded.mobileprovision 解析>"]
}
```

**enroll 成功（HTTP 201）**：

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

**enroll 成功响应说明**：`config` 里的 `networkName`/`networkCIDR`/`iphoneIPv4`/`relayHost`/`relayPort`/`networkSecret`
为旧 VPN/组网契约的兼容占位，设备 agent 当前只使用 `deviceId`、`deviceToken`、`configVersion`，不消费这些网络字段。

**enroll 失败**：注册码不存在/过期/已消费/设备不可注册 → HTTP 401，`{"error":{"code":"IOS_ENROLLMENT_INVALID","message":"注册码无效或已过期，请联系管理员重新签发。"}}`

**status 请求**（`vpnPhase`/`virtualIP`/`peerCount` 为 VPN/组网移除后的固定中性值）：

```json
{
  "appStatus": "online",
  "vpnPhase": "stopped",
  "virtualIP": null,
  "peerCount": 0,
  "lastErrorCode": null
}
```

**WSS envelope**：

```json
{
  "v": 1,
  "type": "agent:heartbeat",
  "msgId": "installation-id:monotonic-sequence",
  "sentAt": "2026-08-06T10:00:00Z",
  "payload": {}
}
```

| 类型 | 方向 | 说明 |
|---|---|---|
| `agent:hello` | 设备 → 平台 | app/iOS/model/locale/configVersion |
| `agent:heartbeat` | 设备 → 平台 | foreground、appStatus、wdaUrl 等 |
| `agent:status` | 设备 → 平台 | 诊断响应/状态变化 |
| `server:ack` | 平台 → 设备 | `ackedMsgId` |
| `server:config_changed` | 平台 → 设备 | 新 configVersion，设备随后 GET /config |
| `server:diagnostic_request` | 平台 → 设备 | `requestId`，返回无敏感诊断 |
| `server:disconnect` | 平台 → 设备 | reason |

WSS 关闭码：`4001` token 无效、`4002` 被新连接替换、`4003` 设备禁用、`4004` 协议/帧非法。
群发 `task:dispatch` 不在此协议（见 §4）。

## 3. WDA 激活与运行（已实现）

- 首次必须 Mac + Xcode + USB：开启开发者模式、签名安装 `WebDriverAgentRunner`。
- `WDA_TEAM=<TeamID> WDA_ENROLL_CODE=<注册码> ./scripts/start-wda.sh --udid <UDID>` 前台常驻，Ctrl-C 停止。
- 付费开发者账号（免费 7 天签名不满足长期运行）；Xcode SDK 版本 ≥ 手机 iOS 版本。

### 3.1 WDA 数据面调用契约（平台 Go 直接实现，无需 Python）

`scripts/wda_whatsapp_broadcast.py` 只是**参考实现**，用来先跑通链路 + 真机验证；生产由平台
Go controller 直接调 WDA HTTP，逻辑完全一致。下面就是 Go 需要实现的请求序列（`<sid>` 为 sessionId，
`<eid>` 为元素 id）。

| # | 目的 | 方法 & 路径 | 请求体 | 关键响应 |
|---|---|---|---|---|
| 1 | 探测 WDA | `GET /status` | - | `{"value":{"ready":true}}` |
| 2 | 启动 WhatsApp | `POST /session` | `{"capabilities":{"alwaysMatch":{"bundleId":"net.whatsapp.WhatsApp","shouldWaitForQuiescence":false}}}` | `{"value":{"sessionId":"<sid>"}}` |
| 3 | 打开手机号会话并预填文本 | `POST /session/<sid>/url` | `{"url":"whatsapp://send?phone=<e164>&text=<urlencoded>","bundleId":"net.whatsapp.WhatsApp","idleTimeoutMs":3000}` | `{"value":{}}` |
| 4 | 定位输入框（多个 TextView 取最靠底） | `POST /session/<sid>/elements` | `{"using":"predicate string","value":"type == 'XCUIElementTypeTextView' AND visible == true AND enabled == true"}` | `{"value":[{"ELEMENT":"<eid>"}]}` |
| 5 | 取输入框文本（回读校验） | `GET /session/<sid>/element/<eid>/text` | - | `{"value":"<text>"}` |
| 6 | 输入文本（深链预填不一致时） | `POST /session/<sid>/element/<eid>/value` | `{"value":["<text>"]}` | `{"value":{}}` |
| 7 | 定位发送键 | `POST /session/<sid>/element` | `{"using":"predicate string","value":"type == 'XCUIElementTypeButton' AND name == 'Send' AND visible == true"}`（label 候选 Send/发送） | `{"value":{"ELEMENT":"<eid>"}}` |
| 8 | 点发送 | `POST /session/<sid>/element/<eid>/click` | `{}` | `{"value":{}}` |
| 9 | 校验输入框已清空 | 重复 4 + 5，文本为 `""` | - | - |
| 10 | 兜底：发送键像素定位 | `GET /session/<sid>/screenshot` + `POST /session/<sid>/actions`（pointerMove/pointerDown/pointerUp） | - | - |
| 11 | 会话失效重建 | `DELETE /session/<sid>` → 回到第 2 步 | - | - |

**Go 侧等价逻辑要点**：

- 手机号 → E.164：`18078526388` → `8618078526388`（去非数字、去 `00`/前导 `0`、按国家码补全）。
- 深链 `whatsapp://send?phone=<e164>&text=<urlencoded>` 可直接对**未保存联系人**开聊，无需搜索通讯录。
- 每条结果结构化上报：`{phone, e164, status, durationMs, attempts, error, steps[]}`；整批 `{summary:{total,sent,failed,durationMs,avgPerItemMs}, items[]}`。
- 单条失败不阻断整批；`failed > 0` 时整批判失败。

## 4. 群发核心业务（待实现）

设备侧只负责「注册 + 心跳 + WDA 直连」；群发的权威执行者是平台侧 controller，经 WDA
`http://<手机局域网IP>:8100` 操作官方 WhatsApp。以下状态机/租约/幂等为**平台侧待实现**设计。

### 4.1 Item 状态机

```text
pending -> leased -> preparing -> click_committed -> sent
   |         |          |               `-------> unknown
   |         |          `-> failed/recovery_required
   |         `-> pending（lease 过期且未 click）
   `-> canceled

failed/recovery_required -> pending（显式 retry/recover，且从未 click）
unknown -> sent（人工 confirmSent）
unknown -> pending（人工 confirmNotSent）
```

禁止转换：`sent -> *`、自动 `unknown -> pending`、`click_committed -> pending`、`canceled -> pending`。
`confirmNotSent` 必须是有权限、有 inspection 证据的人工显式动作，不是自动转换。

### 4.2 租约与幂等要点

- controller 只对 `GET /devices` 返回且 `X-IOS-Controller-ID` 匹配的设备领取 lease。
- 事务内按 global switch → tenant switch → device → item → task 顺序锁定并复核；`SKIP LOCKED`，最多取一行。
- 领取后：item → `leased`、`attempt_count + 1`、lease 90s；task queued → running。
- 同设备严格串行：存在未过期 `leased/preparing/click_committed` item 时不得再 lease。
- click 前持久化 `click_committed` 边界，click 只调用一次；click 后断网/崩溃得到 `unknown`，**不自动重发**。

### 4.3 Lease reaper / 设备恢复

- 每 15s 回收过期 lease：未 click → 回 `pending`；已 click → `unknown`（`LEASE_EXPIRED_AFTER_CLICK`）。
- 设备 `recovery_required` 后停止 lease；管理员 recover：未 click 的 `recovery_required` items 回 `pending`，`unknown` 保持不变。

## 5. 设备生命周期与运营（待实现）

- 探活（probe）、禁用/删除（disable/retire）、恢复（recover）为平台侧待实现项。
- 在线判定依赖设备每 20s `/status` 心跳（90s 超时窗口）；WDA 被终止/设备重启需人工 USB 重新拉起。

## 6. 安全要点

- 注册码为一次性敏感凭证：日志只打印脱敏前缀，不落明文。
- token 只放 `Authorization: Bearer`，服务端存 `SHA-256(token)`；`GET /config` 永不返回 secret/token。
- enroll 路由的 HTTP access log 禁止记录请求/响应 body。
- 日志、指标、WS、审计中不出现 token、secret、完整手机号/正文/截图。

## 7. 已知未完成项

- 平台侧 WSS 服务端（`ws.go`）未落地；当前设备端 WSS 连接会被拒绝/无推送。
- 平台侧 `token/rotate` 路由未注册。
- 群发核心业务（任务/租约/幂等/状态机/unknown）与平台设备管理 API 未实现。
- `deviceUdids` 已按 provisioning profile 解析上报，但平台侧字段消费仍需主仓确认。
