# 评审意见：三端串联实施方案（2026-08-13-wda-farm-three-end-architecture.md）

日期：2026-08-13
状态：评审意见已应用，设计文档已按本意见修订至 v6（2026-08-13）
评审方式：逐项对照源码核验（whatsapp_ai / whatsapp_ai_gateway / WhatsAppDeviceAgent 三个仓库）
评审结论：**方向正确、现状盘点可信度高，可进入 P1；需先修订 H1/H2 并补齐 M1-M3。**

---

## 0. 总体结论

方案整体成熟、可落地：现状盘点与代码高度吻合（逐项核对后绝大多数属实），架构方向正确（WDA 执行下沉网关、手机零直连、复用 WSS 信封与幂等结果回收），分阶段与验收可执行。没有需要推翻重来的架构性问题，但有 2 个高优先级问题、若干重要缺口和一批事实级修正，修订后建议进入 P1。

## 1. 事实核对（与源码逐项对照）

### 核对属实（关键项）

| 文档断言 | 代码证据 |
|---|---|
| `go wda.RunTask` 服务器直连 WDA | `internal/handler/mobile_broadcast.go:49` |
| vpn_ip DDL `INET NOT NULL UNIQUE CHECK` | `internal/store/pg.go:229` |
| `MobileDeviceStatus` 缺 `busy`，DDL 已含 busy | `internal/model/mobile.go:43-49`（无 busy）；`pg.go:234` CHECK 含 `busy` |
| `middleware.Auth` 解析 ActiveTenantID | `internal/middleware/auth.go:65` |
| 移动 WSS 信封 / hello / heartbeat / status / ack / disconnect | `internal/handler/mobile_ws.go`（v/type/msgId/sentAt/payload；关闭码 4001-4004） |
| `MarkMobileBroadcastItemResult` 幂等 | `internal/store/mobile_broadcast.go:187-236`（UPDATE ... WHERE status IN ('pending','sending')，重复上报忽略） |
| `PendingMobileBroadcastTasks` / `ListPendingMobileBroadcastTasksAll` | `internal/store/mobile_broadcast.go:121/144` |
| 无 `UpsertMobileDeviceByUdid` / 网关 WSS / `PushBroadcastTask` | grep 确认不存在，需新增 |
| easytierrpc 为平台侧 easytier RPC 客户端 | `internal/easytierrpc/client.go`（只读 ListPeers/ShowNodeInfo） |
| 平台已有 easytier 配置生成 | `internal/handler/easytier.go`（HandleEasyTierConfigGenerate / buildEasyTierTOML，10.168.0.1/16） |
| iOS 手机直连上报待退役 | `WebDriverAgentRunner/AgentWebSocket.swift`、`WDAAgentRuntime.swift`（/api/ios-agent/v1/ws） |
| 网关现有 Python 原型（无登录） | `whatsapp_ai_gateway/gateway/`（cloud.py 等，无鉴权） |

### 与文档有出入 / 文档未覆盖

1. **§6.2 vpn_ip 清理清单不全**（漏改会编译失败）：
   - `internal/handler/mobile_agent.go:74,97` — `cfg.IPhoneIPv4 = device.VPNIP`（enroll 与 GET /config 两处）
   - `internal/handler/mobile_devices.go:59` — `d.NetworkingConnected = peerSet[d.VPNIP]`
   - `internal/store/mobile_devices.go:160` — enroll 事务内 `SELECT id, status, host(vpn_ip)::text`（文档称"本版不再主用"但代码仍在，删列后必须同步改）
   - 测试文件：`mobile_agent_test.go`、`mobile_devices_test.go` 多处断言 vpn_ip
   - 手机侧 enroll/config/status 整条链路（`mobile_agent.go`、`mobileNetworkConfig`）在"手机零配置"后应整体收敛，不只是删 VPNIP。
2. **§7.2 wda 迁移边界表述**：`phoneinfo` 不是 `internal/wda` 内文件，而是独立包 `internal/phoneinfo`（accounts/connector 也在用）。迁移时应整包复制 `client.go + whatsapp.go + internal/phoneinfo`。已确认 client.go/whatsapp.go 仅依赖标准库 + phoneinfo、无 store 依赖，边界可行。
3. **§9.3 与 §12 自相矛盾**：§9.3 说"无独立 token；账号失效即登录失败"，§12 风险表却说"网关 token 丢失/泄露 → 哈希落盘、管理端吊销重发"。必须二选一（见 H1）。

## 2. 高优先级问题

### H1【阻塞】网关 WSS 复用 `middleware.Auth`（cookie session）与 24h 滑动过期不兼容长连接
- 代码事实：`middleware.Auth` 依赖 `session_id` cookie + 服务端 sessions 表，`SessionByID` 在**每次 HTTP 访问**时把 expires_at 推后 24h（`pg.go:1077-1081`）。
- 问题：WSS 建连后**不再有 HTTP 请求**，网关的 `gateway:heartbeat` 是 WebSocket 帧、不会续期。网关断线超过 24h 重连时 → `SESSION_EXPIRED`（`auth.go:111`），只能人工重新登录，网关静默下线。
- 附带：headless Go 客户端要手动维护 cookie + CSRF token（RequireCSRF 对非 GET 生效），摩擦大；网关与浏览器共用同一账号会话，需确认 sessions 表允许多会话（当前 CreateSession 无 per-user 唯一约束，看起来允许多个，仍要显式验证）。
- **建议**：网关用**独立长期凭证**——沿用项目已有的 per-device token 模式（`mobile_device_enrollment_tokens`：sha256 哈希落库、Bearer 鉴权、可吊销重发，见 `store/mobile_devices.go:101-148` 与 `middleware/mobile_agent_auth.go`），新增网关凭证（可复用同表加 type 列）：网关 WSS 路由用新 middleware（不是 middleware.Auth），租户在签发凭证时绑定。这同时解决 §9.3/§12 的矛盾，"吊销重发"天然成立。
- 若坚持"同一用户登录"，则必须给网关 WSS 单独开**不依赖滑动过期的会话语义**（如网关会话长周期、WSS 心跳续期服务端记录），并在文档写明会话生命周期与续期机制。无论哪条路，文档都要补"网关会话生命周期"一节。

### H2【高】设备 busy 状态无回收，崩溃后永久卡 busy
- 网关执行任务时上报 `busy`；若网关崩溃/断电/断网，无任何机制把该设备从 busy 恢复。
- **建议**：平台侧 reaper——基于网关心跳：网关离线（如 2×20s 无心跳）→ 网关下线 → 其名下设备全部置 offline（或按最近 device:status 的 last_seen 判定）；或对 busy 加 TTL。两者选一，写进 §9 细节，P1 就要带（否则 P3 联调就会踩到）。

## 3. 重要问题（建议修订时补）

### M1【重要】at-least-once 重复发送风险未声明
- 网关执行中途崩溃：已发未报的 item，重连补推后**会再次下发**（task:dispatch 幂等只防重复投递，不防已执行未记账）。WDA 发送不可幂等，重复不可避免。现状服务端 RunTask 同样存在，但执行下沉网关后**窗口变大**（本地进程、断电、拔 USB）。
- **建议**：文档明示"at-least-once，重复窗口 = 本地未记账窗口"，并缩小窗口：网关 executor 对每条 item **先本地持久化结果再上报**（本地 sqlite/文件队列），重连后先补报本地结果、再接收新任务。

### M2【重要】同一设备多任务并发未定义
- 两个任务同时命中同一 device → 两个 task:dispatch 推给同一网关 → 网关需按 UDID 串行执行，interval 节奏跨任务叠加生效。文档只说"单网关并发限流"。
- **建议**：executor 维护 per-UDID 互斥/队列；平台侧同一设备已有 running 任务时可拒新任务或排队（需明确语义）。

### M3【重要】任务取消只有 UI、没有协议
- §8.2 任务视图有"取消"，但 §5.1 协议表无 `task:cancel` 下行，网关 executor 无取消处理。平台 store 已支持 cancelled（MarkMobileBroadcastItemResult 接受 cancelled；tasks CHECK 含 cancelled），只缺协议。
- **建议**：补 `task:cancel {task_id}` 下行 + 网关停止循环 + 未执行 items 置 cancelled。

### M4【中】easytier 后备的价值与成本需要重新论证（或默认关闭）
- WSS 是网关**出站**，easytier 也是网关**出站**。若 WSS 连不上，easytier 大概率也连不上；"平台主动触达网关"WSS 本身已支持服务端→客户端推送。easytier 作为"后备"与 WSS 高度重叠，却引入 network_secret 下发、虚 IP 分配、又一套常驻服务/升级/运维面。
- 手机端移除 easytier 是对的；但网关端保留 easytier 需要**具体失败模式**支撑（例如 WSS 端口被封但 easytier 中继可达、或平台需在 WSS 断开时紧急踢线/下发重启指令）。当前表述（"WSS 断线 / 平台主动触达兜底"）不足以证明必要性。
- **建议**：v1 纯 WSS（断线重连 + 补推 + 本地持久化已覆盖大部分故障），easytier 降级为**可选能力、默认关闭**，等出现真实失败模式再按 ADR 引入；即便引入，也把网关侧 easytier 服务放 P4/P5 而非 P2 主链路。

### M5【中】设备归属 / 网关命名的边界要写死
- controller_id=网关名：需定义同用户下网关重名策略（自动后缀/注册校验），否则 hub 替换/串设备。
- `UpsertMobileDeviceByUdid` 建议键 = **(tenant_id, udid)** 组合唯一（同一 UDID 出现在不同租户/网关时不能互相覆盖）；文档"按 UDID 唯一"不精确。
- 新设备自动创建时的默认 name/status 需定义（现状 CreateMobileDevice 默认 pending_enrollment + "移动设备"）。

### M6【中】网关离线时设备状态不联动
- 网关离线（心跳超时）→ 组网页网关卡片变灰（hub 内存态），但其下设备状态不更新，管理端看到 stale online。
- 建议：网关心跳 reaper 联动设备状态（同 H2，一并设计）。

## 4. 低优先级 / 文档一致性

1. 标题 v4 vs 头部 v5；§7.1 编号重复（两个 5、两个 6）；§9 编号重复（两个 10）。
2. **§7.1 平台侧退役清单缺失**：手机直连退役（P5）后，平台侧 `mobile_ws.go` / `mobile_agent.go`(enroll/config/status) / 手机 easytier 相关是否停用/删除未列。建议明确"先停用再删"或"保留兼容"。
3. **容量证据**：8~20 台/网关是"实测待定"而非已验证，P0 只跑通单台。建议把"单台 Mac 并发 xcodebuild 激活上限、USB hub 供电、WDA 常驻内存"实测提前到 P3/P4，不要留到 P6 才发现带机量不足。
4. **easytierrpc 现状只读**："复用 easytier 服务端分配 gateway_ipv4"——生成配置有 HandleEasyTierConfigGenerate，IP 分配可复用 nextSequentialVPNIP 的 advisory lock 模式改名给网关用；但 easytierrpc 无写操作，若未来需要 RPC 管理 peer/路由需另评估（v1 不需要）。
5. item:result 租户校验：MarkMobileBroadcastItemResult 的 item UPDATE 不含 tenant_id（靠 task_id 归属），聚合 UPDATE 含 tenant_id，现状隔离基本成立；网关侧校验仍建议保留（文档已写）。

## 5. 结论与建议顺序

- 结论：方案方向正确、现状盘点可信度高，达到"可落地评审版"标准；修订 H1/H2 + 补齐 M1-M3 后可进入 P1。
- 建议落地顺序：
  1. 定网关鉴权方案（H1）→ 决定是否新增网关凭证（推荐）；
  2. 补设备状态回收（H2）+ 网关离线联动（M6）为同一设计块；
  3. 补 task:cancel 协议（M3）与 at-least-once 声明 + 本地持久化（M1）；
  4. vpn_ip 清理清单补全（§6.2 遗漏的调用点 + 测试）；
  5. 修订文档编号/版本矛盾，明确平台侧退役清单；
  6. P1-P3 按原计划推进，但把"网关离线→设备离线→重连续发"作为 P3 验收用例（现在 P3 验收只有"一 Mac 一 iPhone 发送成功"）。
