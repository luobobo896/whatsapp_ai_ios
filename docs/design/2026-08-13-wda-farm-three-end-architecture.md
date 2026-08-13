# 三端串联实施方案（可落地评审版 v6）

日期：2026-08-13（v6：按 2026-08-13 评审意见修订——网关改用独立网关凭证登录，不复用浏览器会话；easytier 降级为可选能力、默认关闭；补 busy/离线状态回收、task:cancel、at-least-once 执行语义。v5：网关=Mac mini 应用，平台配置只下发本地网关应用）
仓库：
- `whatsapp_ai`（云平台，Go）：`~/work/个人文档/whatsapp_ai`
- `whatsapp_ai_gateway`（本地网关）：`~/work/个人文档/whatsapp_ai_gateway`
- `whatsapp_ai_ios`（手机 WDA）：`~/work/个人文档/whatsapp_ai_ios/WhatsAppDeviceAgent`

---

## 0. 结论先行

1. 平台**已实现**"服务器直连手机 WDA 驱动群发"（`internal/wda` + `HandleMobileBroadcastCreate` 里 `go wda.RunTask`）。
2. 本轮目标 = **把 WDA 执行下沉到本地网关**，网关主走**手机局域网 IP（192.168.x.x）直连 WDA**。
3. **easytier 降级为可选能力、默认关闭**：v1 主链路纯 WSS（断线重连 + 补推 + 网关本地持久化）；仅当出现真实失败模式（如 WSS 端口被封但 easytier 中继可达）再按 ADR 引入，网关按平台下发的配置启动集成的 easytier 服务；手机不再跑 easytier。
4. **登录模型**：**网关用独立网关凭证登录**（同账号体系、绑定租户，但不是浏览器会话；sha256 哈希落库、Bearer 鉴权、可吊销重发）。配置只下发到网关（Mac mini），**手机零配置下发、零直连**。

---

## 1. 目标与非目标

### 1.1 目标
- 100 台 iPhone 7×24 在线群发，网关激活/看护 WDA。
- `wda_url` = 手机局域网 IP `http://192.168.x.x:8100`（主通道）。
- easytier 作为**可选**后备服务（默认关闭）：仅在需要时由平台下发配置给本地网关应用 → 网关启动 easytier 服务。
- 网关用**独立网关凭证**登录（复用账号体系、绑定租户）；统一注册/上报设备、回收发送结果；配置只下发到网关（Mac mini），手机零直连、零配置下发。

### 1.2 非目标
- 不改 WhatsApp 深链/选择器方案（沿用 `internal/wda/whatsapp.go`）。
- 不做 Android；不做网关多实例高可用（先单 Mac mini 单网关）。

---

## 2. 现状盘点（精确到代码）

| 模块 | 文件 | 现状 |
|---|---|---|
| 设备/任务模型 | `internal/model/mobile.go` | `MobileDevice`（udid/wda_port=8100/controller_id/status/wda_url/vpn_ip）、`MobileBroadcastTask/Item`、`MobileAgentConfig`（easytier 网络配置） |
| 设备注册 | `internal/store/mobile_devices.go` | `ConsumeTenantEnrollmentCode`（per-device token，**本版不再主用**）、`CreateMobileDevice`（自动分配 vpn_ip） |
| 广播 store | `internal/store/mobile_broadcast.go` | ✅ 建任务+明细、`MarkMobileBroadcastItemResult`（幂等聚合+自动 done）、`PendingMobileBroadcastTasks`/`ListPendingMobileBroadcastTasksAll` |
| WSS 服务 | `internal/handler/mobile_ws.go` | ✅ 信封、Bearer per-device 鉴权、hello/heartbeat/status、ack/diagnostic/disconnect |
| 设备侧 REST | `internal/handler/mobile_agent.go` | `POST /api/ios-agent/v1/enroll` |
| 管理端 REST | `internal/handler/mobile_devices.go` | 设备列表/enrollment-code/PATCH/DELETE/events/diagnostic/broadcast |
| 群发 REST | `internal/handler/mobile_broadcast.go` | `POST /:id/broadcast` → `go wda.RunTask`（**待改造**） |
| WDA 执行 | `internal/wda/*.go` | `Client`/`RunTask`/`SendMessageToPhone` |
| 组网 | `internal/easytierrpc/*` | 平台侧 easytier 服务端 RPC（peer 管理） |

**平台侧缺口**：
- ① 无 `gateways` 实体与**网关凭证**（表、签发/吊销接口、Bearer 鉴权 middleware）。
- ② `mobile_ws.go`/网关通道无 `task:dispatch` 下行、`item:result` 上行。
- ③ `HandleMobileBroadcastCreate` 仍直连 WDA。
- ④ 无 `UpsertMobileDeviceByUdid`（网关按 UDID 上报用）。
- ⑤ easytier 配置下发接口（平台→网关）需新增。

---

## 3. 目标架构

```text
[ whatsapp_ai 云平台 ]
  ├─ server：管理端 REST + 网关 WSS（任务下发 / 结果回收）
  ├─ PostgreSQL：mobile_devices / broadcast_tasks / items
  └─ easytier 服务端（可选，默认关闭）
        │ WSS 主链路：网关凭证登录 / 上报设备 / 收任务 / 报结果
        │ easytier 后备链路（仅启用时）：平台服务端 ⇄ 网关 easytier 服务
        ▼
[ whatsapp_ai_gateway（Mac mini 本地应用） ]
  ├─ 登录入口（独立网关凭证 → 用户/租户）
  ├─ easytier 服务（可选，默认关闭）
  ├─ WDA 激活 / 看护 watchdog
  └─ WDA 执行器
        │ http://192.168.x.x:8100（手机局域网 IP）
        ▼
[ 手机（只跑 WDA） ]
  ├─ iPhone 1 · WDA :8100
  └─ iPhone N · WDA :8100
```



### 3.1 whatsapp_ai_gateway = Mac mini 上的网关应用

网关是一个独立应用（跑在 Mac mini 上），由以下部分组成：

| 组件 | 职责 |
|---|---|
| **登录入口** | 用**独立网关凭证**登录 → 获取**用户 + 租户**信息（凭证绑定租户、可吊销） |
| **easytier 服务** | **可选（默认关闭）**：网关集成 easytier 服务；仅在平台下发配置后才启动（后备通道，按需启用） |
| **WDA 激活 / 看护 watchdog** | 激活 WDA、健康检查、自动重激活 |
| **WDA 执行器** | 收任务 → 驱动手机 WDA 发送 → 回报结果 |

### 3.2 与平台、手机的关系

- **平台**：网关登录后建立 WSS（主链路）：上报设备 / 状态 / 结果，接收任务与配置。
- **手机**：只跑 WDA，被网关经 `192.168.x.x:8100` 驱动；零直连平台、零配置下发、不跑 easytier。
- **两条链路**：WSS 是唯一业务控制链路；easytier 是网关集成的**可选**后备服务（默认关闭），**与手机无关**。

### 3.3 数据流要点

1. 管理端建任务 → 落库 → 平台按 `controller_id`（网关实例名）路由 → `task:dispatch` 推给对应网关。
2. 网关 WDA 执行器逐条驱动手机 → `item:result` 回报 → 平台幂等聚合。
3. 设备/App 信息由网关从 USB+WDA 采集 → `device_list` 上报 → 平台按 UDID upsert。
4. 所有配置（easytier 等）只下发到网关（Mac mini），手机零配置。

## 4. 端到端时序

### 4.1 网关凭证登录 + 设备上报（easytier 可选）
```
网关 --网关凭证(Bearer)--> wss://.../gateway/ws
网关 --> gateway:hello {name,version}
平台 --> server:ack（解析 tenant；凭证吊销/过期则 4005 关闭）
[仅 easytier 启用时] 平台 --> 网关: easytier:config {network_name,secret,relay_host,relay_port,gateway_ipv4}
[仅 easytier 启用时] 网关 --> 用配置启动集成的 easytier 服务，加入 mesh（后备通道就绪）
网关 --> device_list [{udid,name,model,ios_version,wda_ip,wda_port,wda_status}]
平台 --> 按 (tenant,udid) upsert mobile_devices（controller_id=网关ID，wda_url=http://wda_ip:8100）
网关 --每 20s--> gateway:heartbeat（服务端更新 last_seen_at）
```

### 4.2 群发任务
```
管理端 --> POST /api/ios-devices/:id/broadcast {content,phones,intervalSec}
平台 --> 建 task+items（pending）
平台 --> 网关 task:dispatch {task_id,device_id,udid,content,interval_sec,items:[{item_id,phone,seq}]}
loop 每条 item:
  网关 --> 手机 WDA(udid, 192.168.x.x:8100): 建 session→whatsapp://send?phone→输入→发送
  网关 --> 平台 item:result {task_id,item_id,phone,status,error,duration_ms}
  平台 --> MarkMobileBroadcastItemResult（幂等，sent/failed 聚合）
end
平台 --> sent+failed>=total → done
管理端取消 --> 平台 task:cancel 下行 --> 网关停循环，未执行 items 置 cancelled
```

断线续发（平台已有）：网关重连后补推 `PendingMobileBroadcastTasks`；平台启动扫描补推。执行语义为 **at-least-once**：网关每条 item 先本地持久化结果再上报，重连先补报本地结果再收新任务。

---

## 5. 接口契约

### 5.1 网关登录 WSS（新增）

信封：`{"v":1,"type":"...","msgId":"...","sentAt":"...","payload":{...}}`
鉴权：**独立网关凭证**（`gateway_tokens`：sha256 哈希落库、Bearer 头携带、绑定租户、可吊销重发）；网关 WSS 路由用**新增 middleware**（不复用 `middleware.Auth` 的 cookie session，避免 24h 滑动过期与长连接不兼容）；`gateway:hello` 携带网关实例名。

| 方向 | type | 说明 |
|---|---|---|
| 上行 | `gateway:hello` | `{name,version}` 登录首帧 |
| 上行 | `gateway:heartbeat` | 20s 保活 |
| 上行 | `device_list` | `[{udid,name,model,ios_version,wda_ip,wda_port,wda_status,whatsapp_version}]` |
| 上行 | `device:status` | `{udid,wda_status,error}` 单台变化 |
| 上行 | `item:result` | `{task_id,item_id,phone,status,error,duration_ms}` |
| 上行 | `task:summary` | 可选 `{task_id,sent,failed,total}` |
| 下行 | `server:ack` | 沿用 |
| 下行 | `task:dispatch` | `{task_id,device_id,udid,content,interval_sec,items:[{item_id,phone,seq}]}` |
| 下行 | `task:cancel` | `{task_id}` 停止该任务，未执行 items 置 cancelled |
| 下行 | `easytier:config` | **可选**：`{network_name,network_secret,relay_host,relay_port,network_cidr,gateway_ipv4}`（仅 easytier 启用时下发到本地网关应用） |
| 下行 | `server:disconnect` | 沿用 |

### 5.2 平台 REST

| 端点 | 现状 | 改动 |
|---|---|---|
| `POST /api/ios-agent/v1/gateway/ws` | 无 | 新增：网关 WSS（**独立网关凭证**，Bearer 鉴权，非 cookie session） |
| `GET /api/network/gateways` | 无 | 新增：组网页网关实例列表（来自网关 WSS hub 在线态） |
| `POST /api/network/gateways` | 无 | 新增：签发网关凭证（租户内唯一 name，返回 token 明文一次） |
| `POST /api/network/gateways/:id/revoke` | 无 | 新增：吊销网关凭证（踢掉在线 WSS，重连拒绝） |
| `POST /api/ios-devices/:id/broadcast` | `go wda.RunTask` | 改为经网关 `PushBroadcastTask` |

### 5.3 网关本地 REST/Web

| 端点 | 说明 |
|---|---|
| `GET /api/devices` | 本机发现+已上报设备 |
| `POST /api/devices/{udid}/activate` / `stop` | WDA 激活/停止 |
| `GET /api/devices/{udid}/metrics` | 本地发送指标 |
| `POST /api/devices/{udid}/report` | 本地/调试结果上报 |

---

## 6. 数据模型

### 6.1 网关实例与网关凭证

- **网关凭证表 `gateway_tokens`（新增，鉴权与吊销的持久化依据）**：
  `{id, tenant_id, name(如 macmini-01，租户内唯一), token_hash(sha256), created_at, revoked_at, last_seen_at}`；token 明文仅签发时返回一次；`gateway:hello` 以 name 关联实例。
- **网关实例本体**：由网关 WSS hub 在内存跟踪（连接态）：
  `{token_id, tenant_id, name, connected_at, last_heartbeat, easytier_ip, device_count}`。
- 组网页从 hub 读在线网关实例；离线记录复用 `gateway_tokens.last_seen_at`（每心跳更新），**不另建会话表**，保持最小。
- **会话生命周期**：网关凭证**不随浏览器 session 过期**；服务端每收到 `gateway:heartbeat` 更新 `last_seen_at`；凭证吊销即踢线（关闭码 4005），重连拒绝；吊销后可重发新凭证。

### 6.2 `mobile_devices` 调整（移除 vpn_ip）

- **彻底移除 `vpn_ip` 列**（手机不再跑 easytier，per-phone 虚 IP 概念废弃）：
  ```sql
  ALTER TABLE mobile_devices DROP COLUMN vpn_ip;
  ```
- `wda_url`：网关上报 `wda_ip`（手机局域网 IP）→ 平台存 `wda_url = http://<wda_ip>:8100`。
- `controller_id`：改为网关实例名（如 `macmini-01`，用户/租户内唯一）。
- 新增 store 方法 `UpsertMobileDeviceByUdid(tenant, gatewayID, info)`：按 **(tenant_id, udid) 组合唯一**更新 `wda_url/status/型号/iOS 版本/locale/whatsapp_version`，不存在则创建；同一 UDID 出现在不同租户/网关时互不覆盖；新设备默认 `name="移动设备"`、`status=online`（网关已激活 WDA 即视为在线）；`wda_status → status` 映射：`online→online`、`busy→busy`、其余→`offline`。

**vpn_ip 关联代码点（全部移除/改造）**：

| 位置 | 改动 |
|---|---|
| `store/pg.go` DDL | 删 `vpn_ip INET NOT NULL UNIQUE CHECK` 列 |
| `model/mobile.go` | 删 `VPNIP` 字段；`NetworkingConnected`、`MobileStatusReport.VPNPhase/VirtualIP/PeerCount`（手机侧 easytier 状态）废弃 |
| `store/mobile_devices.go` | 删 `mobileDeviceColumns`/`listMobileDeviceColumns`/`scanMobileDevice` 中的 `host(vpn_ip)`；`CreateMobileDevice` 与注册事务不再分配 vpn_ip；删 `nextSequentialVPNIP`/`nextSequentialVPNIPTx`（虚 IP 分配逻辑迁到网关 `easytier_ip` 分配）；**`ConsumeTenantEnrollmentCode` 事务内 `SELECT id, status, host(vpn_ip)::text` 同步移除 `host(vpn_ip)`** |
| `handler/mobile_agent.go` | 删 `cfg.IPhoneIPv4 = device.VPNIP`（`HandleMobileAgentEnroll` 与 `HandleMobileAgentConfig` 两处）；enroll/config/status 手机侧链路随"手机零配置"整体收敛 |
| `handler/mobile_devices.go` | 删 `d.NetworkingConnected = peerSet[d.VPNIP]`（设备列表不再与 easytier peer 匹配） |
| 测试 | `mobile_agent_test.go`、`mobile_devices_test.go` 中 vpn_ip 断言同步更新 |

---

## 7. 各端改造清单

### 7.1 平台 `whatsapp_ai`（Go）

1. **网关凭证与鉴权**：新增 `gateway_tokens` 表 + 签发/吊销 REST + 网关 WSS 专用 middleware（Bearer 校验 token_hash、解析 tenant）；`handler/gateway_ws.go` 的 hub 按 (tenant, name) 跟踪在线网关实例；`main.go` 挂载 `/api/ios-agent/v1/gateway/ws`。
2. **网关 WSS 协议**：`gateway:hello{name}`、`gateway:heartbeat`（更新 `last_seen_at`）、`device_list`→`UpsertMobileDeviceByUdid`、`device:status`、`task:dispatch`/`task:cancel` 下行、`item:result`/`task:summary` 上行。
3. **任务下发改造与路由**：`HandleMobileBroadcastCreate` 去掉 `go wda.RunTask`；按设备 `controller_id`（=网关ID）找到在线网关 WSS 连接，`PushBroadcastTask(device)` 下发；网关离线则保持 pending，网关重连时补推。
   - `gatewayHub` 维护 `gatewayID → gatewayClient` 映射；`PushBroadcastTask` 从 `mobile_broadcast_items` 组出 `items:[{item_id,phone,seq}]`，并在 payload 携带 `udid`。
   - **同一设备并发任务**：平台侧同一 device 已有 running 任务时，新任务保持 pending（网关 executor 再按 UDID 串行兜底）。
4. **结果回收与租户校验**：`item:result` 上行时，网关 hub 以网关凭证解析出的 tenant 校验 `task_id/device_id` 归属（防止越权上报）；校验通过才 `MarkMobileBroadcastItemResult`。
5. **取消**：`task:cancel` 下行 → 网关停循环；未执行 items 由平台置 cancelled。
6. **状态回收（busy/离线）**：网关心跳 reaper——网关离线（2×20s 无心跳）→ 网关下线 → 其名下设备置 offline；设备 `busy` 超过 TTL（如 10min）未见恢复 → 重置为 offline；补 `MobileDeviceStatusBusy = "busy"` 常量。
7. **easytier 配置生成（可选）**：仅 easytier 启用时，复用 easytier 服务端为网关分配 `gateway_ipv4`（advisory lock 模式沿用 `nextSequentialVPNIP` 改名给网关用）并生成 `easytier:config` 下发；网关实例 `easytier_ip` 记录在 hub 内存。
8. **移除 vpn_ip**：按 6.2 清单清理 DDL/model/store/handler/测试；`easytierrpc` 服务端保留（网关集成的 easytier 服务连接用）。
9. **平台侧手机直连退役**：P5 起停用 `mobile_ws.go` 网关通道与 `mobile_agent.go` 的 enroll/config/status（先停用再删，避免误伤）；`internal/wda` 保留（下沉网关复用）。

### 7.2 网关 `whatsapp_ai_gateway`（Go）

```
whatsapp_ai_gateway/
├── cmd/gateway/main.go
├── internal/
│   ├── config/       # 平台 wss url、网关凭证、设备清单
│   ├── devices/      # USB 发现（devicectl/ioreg）+ UDID→局域网IP
│   ├── session/      # 网关 WSS：凭证登录/心跳/device_list/收 task:dispatch/task:cancel（+ easytier:config 可选）
│   ├── easytier/     # 集成的 easytier 服务（可选，默认关闭）：接收平台配置后启动（后备）
│   ├── wda/          # ★ 从平台 internal/wda 迁移复用
│   ├── executor/     # task:dispatch/task:cancel → 发送循环（per-UDID 串行）→ 本地持久化 → item:result
│   ├── watcher/      # WDA 激活/看护 watchdog
│   ├── metrics/      # 本地指标
│   └── web/          # 本地 REST + 管理页
├── devices.json
└── go.mod
```

- **wda 迁移边界**：只迁 `client.go` + `whatsapp.go` + **`internal/phoneinfo` 包**（`runner.go` 的 store 写库逻辑不迁，由 executor 改为发 `item:result`）。
- `wda_url` 一律用手机局域网 IP `http://<ip>:8100`。
- 仅在收到 `easytier:config`（默认不启用）后，本地网关应用才启动集成的 easytier 服务加入 mesh，获得虚 IP 作为后备。
- **executor 执行语义**：同一 UDID 的任务串行执行；每条 item **先本地持久化结果再上报**；收到 `task:cancel` 停止循环并把未执行 items 标 cancelled 上报。
- **设备信息采集（手机不自报）**：
  - UDID / 型号 / iOS 版本 / 语言：USB 直连时从 `devicectl` / `ioreg` 读取；
  - OS 信息：WDA `GET /status`；
  - 已安装 App（含 WhatsApp 版本）：优先 `devicectl device info apps`（权威）；WDA `GET /wda/apps/list` 作兜底（其 handler 名 `handleGetActiveAppsList`，可能仅活跃应用，需实测）；
  - 汇总进 `device_list` / `device:status` 上报平台。

### 7.3 手机 `whatsapp_ai_ios`

- **不改** WebDriverAgent HTTP 服务与 `start-wda.sh`（网关按 UDID 激活）。
- 手机 `AgentWebSocket.swift` 直连上报退役；手机不再运行 easytier，**也不再自身上报设备/App 信息**——这些由网关经 USB+WDA 采集后上报。
- 真机联调校准 WhatsApp 选择器。

---

## 8. 管理端 UI/UX（组网 → 网关 → 设备列表）

### 8.1 信息架构（用户主流程，钻取式）

```
侧边栏「组网」
  └─ 组网页：网关卡片列表（每卡片：名称/状态/设备数/在线数/最后心跳）
       └─ 点击网关 → 网关详情页 = 该网关的设备列表
            ├─ 面包屑：组网 / <网关名> / 设备
            └─ 行操作：激活 WDA / 停止 / 设 IP / 查看任务
```

### 8.2 页面设计（围绕用户体验）

1. **组网页（网关总览）**
   - 网关卡片：名称、状态（在线/离线，绿/灰）、设备总数、在线数、最后心跳时间
   - 操作：签发/查看网关凭证（独立凭证，可吊销）、重连提示、断开（踢掉 WSS 连接）
   - 离线网关置灰 + 告警角标；点击卡片进入设备列表
2. **网关详情页（设备列表）**
   - 顶部：网关信息 + 统计（总数/在线/忙碌/离线）+ 全局搜索入口
   - 设备表格列：UDID、型号、iOS 版本、状态（online/busy/offline）、WDA 健康、局域网 IP:8100、WhatsApp 版本、最近发送任务
   - 状态实时刷新（轮询或 WSS 推送）；分页/虚拟滚动（支持 100 台）
3. **全局设备视图（增强，两条路都通）**
   - 顶部导航「设备」：跨网关统一设备列表，支持按网关筛选、按 UDID/手机号搜索
   - 满足"直接找某台手机"的场景，不必先点网关
4. **任务视图**
   - 设备任务页：群发进度（sent/failed/total）、逐条明细（status/error/duration）、取消
   - 发送结果（成功/失败数）实时展示

### 8.3 前端路由建议

```
/network                组网页（网关总览）
/network/gateways/:id   网关详情 = 该网关设备列表
/devices                全局设备列表（按网关筛选/搜索）
/devices/:id/tasks      设备群发任务
```

### 8.4 为什么这样设计

- 网关 = 物理控制单元（一台 Mac mini + 一批手机），按网关钻取符合运维直觉；
- 全局设备视图兜底"直接找手机"的诉求，两条路径都通；
- 状态（在线/忙碌/离线）贯穿组网→网关→设备三层，一眼定位问题。

---
## 9. 关键细节与坑

1. **wda_url 主通道**：`http://<手机局域网IP>:8100`；手机需稳定在网关所在局域网（关自动锁屏、Wi-Fi 不断）。
2. **easytier 后备（可选，默认关闭）**：v1 主链路纯 WSS（断线重连 + 补推 + 网关本地持久化已覆盖大部分故障）；仅当出现真实失败模式（如 WSS 端口被封但 easytier 中继可达、或平台需在 WSS 断开时紧急触达网关）才启用——平台把配置只下发给**本地网关应用（Mac mini）**，网关据此启动集成的 easytier 服务，平台经网关实例 `easytier_ip` 触达。手机不跑 easytier、不收任何配置。
3. **网关凭证与会话生命周期**：网关用**独立网关凭证**（`gateway_tokens`：sha256 哈希落库、Bearer 鉴权、绑定租户、可吊销重发）。**不复用 `middleware.Auth` 的 cookie session**（24h 滑动过期只在 HTTP 请求时续期，WSS 长连接心跳不会续期，断线 >24h 重连会 `SESSION_EXPIRED`）。服务端每心跳更新 `last_seen_at`；凭证吊销即踢线（4005）并拒绝重连。
4. **租户归属**：网关凭证签发时绑定 tenant，`gateway:hello` 后全部落在该租户；`item:result` 按凭证解析出的 tenant 校验归属。
5. **设备 upsert 幂等**：按 **(tenant_id, udid)** 组合唯一，重复上报只更新；同一 UDID 跨租户/跨网关不互相覆盖。
6. **断线续发**：平台已就绪；网关 executor 对重复 `task:dispatch` 幂等。
7. **节奏/并发**：`interval_sec` 网关生效；单网关并发限流；**同一 UDID 的任务由网关 executor 串行执行**（平台侧同一 device 已有 running 任务时新任务保持 pending）。
8. **WDA 会话生命周期**：watchdog 健康检查+自动重激活。
9. **深链限制**：陌生号码可能静默失败/降权，沿用风控声明。
10. **任务执行中设备状态 + busy 回收**：网关收到 `task:dispatch` 后报该设备 `device:status {wda_status:"busy"}`，完成/失败后恢复 online；平台据此把设备标 busy/online。注意平台 `model.MobileDeviceStatus` 常量**当前缺 `busy`**，需补 `MobileDeviceStatusBusy = "busy"`（DDL 已含 busy）。**busy 必须有回收**：网关心跳 reaper——网关离线（2×20s 无心跳）→ 其名下设备置 offline；busy 超过 TTL（如 10min）未见恢复 → 重置为 offline。
11. **网关重连**：重连后先 `gateway:hello` → 重新上报 `device_list`（平台按 UDID upsert 幂等）→ 平台补推 `PendingMobileBroadcastTasks`。
12. **item:result 记账键**：平台 store `MarkMobileBroadcastItemResult` 以 `item_id` 为主键（网关从 `task:dispatch.items` 获得），幂等；网关不得自行造 item_id。
13. **at-least-once 语义**：网关执行中途崩溃会重推未记账 item，重复发送不可避免；网关每条 item **先本地持久化结果再上报**，重连先补报本地结果再收新任务，把重复窗口压缩到"本地未记账窗口"。
14. **设备信息采集**：UDID/型号/iOS 版本/语言从 USB（devicectl/ioreg）读；WhatsApp 版本等已安装 App 信息从 WDA `GET /wda/apps/list`（或 `devicectl device info apps`）读；全部由网关汇总上报，手机不自报。

---

## 10. 部署拓扑

- Mac mini ×M，每台一个网关实例；USB 独立供电扩展坞挂 8~20 台 iPhone；100 台 ≈ 5~12 台。
- 每台 iPhone：一次性信任配对、关自动锁屏、常驻充电、连网关所在局域网。
- WDA 可达：**主** 手机局域网 IP `http://192.168.x.x:8100`；**备（仅 easytier 启用时）** 网关 easytier 虚 IP + 转发。
- 每网关一条出站 WSS（**独立网关凭证**，非浏览器会话）+ 网关内 easytier 服务（**可选，默认关闭**）。
- 开发者账号付费（100 台上限），提前注册全部 UDID。

---

## 11. 分阶段实施（含验收）

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 | Python 原型 | ✅ 已跑通单台 |
| P1 | 平台：**移除 `vpn_ip`（DDL+代码清理，含 handler/测试）** + 网关凭证（签发/吊销/Bearer 鉴权）+ 网关 WSS（device_list upsert/heartbeat/last_seen） | 签发网关凭证→网关登录→平台看到网关实例与设备清单（wda_url=局域网IP）；吊销凭证→网关被踢且重连拒绝 |
| P2 | 平台：`task:dispatch`/`task:cancel`/`item:result` + broadcast 改网关下发 + busy 状态回收 reaper | 建任务→推帧；取消任务→网关停循环；item:result 落库幂等；busy 超时自动回收 |
| P3 | 网关 Go：config/devices/session/wda 复用/web；凭证登录→激活→收 task→发送→item:result（本地持久化 + per-UDID 串行） | 一 Mac+一 iPhone：平台建任务→手机发送→sent/failed 正确；**网关离线→设备置 offline→重连补推续发** |
| P4 | 网关 executor 节奏/断线续发/watchdog 自愈 + 本地持久化队列 | 拔插/杀 WDA 自动恢复；重连续发；崩溃后已发未报 item 重复窗口最小化 |
| P5 | iOS 侧收敛（手机直连退役）+ 平台侧手机直连链路停用/清理 + 选择器校准 | 平台只见网关，手机零直连 |
| P6 | 多台扩展 + 100 台联调 + 运维；多机实测 xcodebuild 并发激活上限/USB 供电/WDA 常驻内存 | 100 台稳定，宕机自愈；容量假设有实测证据 |

> easytier（可选）不在主链路验收内：仅在出现真实失败模式（WSS 端口被封但 easytier 中继可达等）后按 ADR 引入，作为 P6 之后的独立增量。

---

## 12. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 单台 Mac 带机上限 | 8~20 台/网关实测；并发限流 |
| 手机局域网 IP 变动 | 网关周期重扫，`device:status` 上报新 IP |
| USB 供电不足掉线 | 独立供电扩展坞；watchdog 重连 |
| 开发者账号 100 台上限 | 付费号一次性注册 UDID |
| WDA 会话被回收 | watchdog 自动重激活 |
| 网关凭证丢失/泄露 | 哈希落盘（仅存 sha256）、管理端吊销重发（与浏览器会话隔离） |
| 网关崩溃致设备卡 busy | 网关心跳 reaper：网关离线→设备置 offline；busy TTL 重置 |
| 崩溃窗口重复发送 | 明示 at-least-once；网关本地持久化结果、先补报再收新任务，压缩重复窗口 |
| WhatsApp 选择器变化 | 可覆盖选择器 + 截图/LLM 兜底 |
| 群发风控/封号 | 沿用平台声明、速率/配额/送达率告警 |

---

## 13. 附录：消息示例

```json
// 网关登录（WSS 握手携带 Authorization: Bearer <gateway_token>）
{"v":1,"type":"gateway:hello","msgId":"g:1","sentAt":"...","payload":{"name":"macmini-01","version":"0.1.0"}}

// 平台 → 本地网关应用：easytier 配置下发（仅 easytier 启用时；网关据此启动其集成的 easytier 服务）
{"v":1,"type":"easytier:config","msgId":"srv:1","sentAt":"...","payload":{
  "network_name":"wa-ios","network_secret":"...","relay_host":"...","relay_port":11010,
  "network_cidr":"10.168.0.0/16","gateway_ipv4":"10.168.1.2"}}

// 网关 → 平台：上报名下设备（wda_url 用局域网 IP）
{"v":1,"type":"device_list","msgId":"g:2","sentAt":"...","payload":{"devices":[
  {"udid":"5060c403...","name":"iPhone","model":"iPhone9,2","ios_version":"15.8.7","wda_ip":"192.168.20.33","wda_port":8100,"wda_status":"online"}
]}}

// 平台 → 网关：任务下发
{"v":1,"type":"task:dispatch","msgId":"srv:2","sentAt":"...","payload":{
  "task_id":"t1","device_id":"d1","udid":"5060c403...","content":"你好","interval_sec":20,
  "items":[{"item_id":"i1","phone":"+8613800000000","seq":1}]}}

// 网关 → 平台：单条结果
{"v":1,"type":"item:result","msgId":"g:3","sentAt":"...","payload":{"task_id":"t1","item_id":"i1","phone":"+8613800000000","status":"sent","error":"","duration_ms":3200}}

// 平台 → 网关：取消任务
{"v":1,"type":"task:cancel","msgId":"srv:3","sentAt":"...","payload":{"task_id":"t1"}}
```
