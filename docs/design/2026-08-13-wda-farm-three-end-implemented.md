# 三端串联 v6 实施记录（2026-08-13）

> 对应设计：`docs/design/2026-08-13-wda-farm-three-end-architecture.md`（v6）
> 分支策略：三端全部固定在 `main-test` 分支（新建），**未触碰生产 `main`**。

## 各端改动与分支

| 端 | 仓库 | 分支 | 关键改动 |
|---|---|---|---|
| 云平台 | `whatsapp_ai` | `main-test` | 网关凭证 `gateway_tokens`（签发/吊销/哈希落库/Bearer 鉴权）；网关 WSS `GET /api/ios-agent/v1/gateway/ws`（gateway:hello/heartbeat/device_list/device:status/item:result/task:summary 上行，task:dispatch/task:cancel/server:ack 下行）；`HandleMobileBroadcastCreate` 改经网关下发（离线保持 pending，重连补推）；取消接口；busy/离线 reaper；`mobile_devices` 移除 `vpn_ip` + 新增 `UpsertMobileDeviceByUdid` + `whatsapp_version` 列复用；前端「组网」页（网关卡片/签发吊销凭证/网关设备钻取）+ 菜单 seed |
| 本地网关 | `whatsapp_ai_gateway`（新建 git） | `main-test` | 沿用 P0 Python 原型扩展（**未做 Go 重写，见下**）：Bearer 凭证登录、gateway:hello/heartbeat、device_list 上报、task:dispatch 执行器（per-UDID 串行 + 本地持久化 `data/results` + at-least-once 重连补报）、task:cancel、device:status、WhatsApp 发送流程（移植平台 `internal/wda/whatsapp.go`）、Web 页云通道状态 |
| 手机 WDA | `whatsapp_ai_ios/WhatsAppDeviceAgent` | `main-test` | `AgentWebSocket.swift` 直连上报退役（`agentDirectReportingEnabled=false` 可回滚对照）；`embed-runner-icon.sh` 签名身份自动挑选有效 Apple Development 证书（修复已吊销 129DCD81... 导致的 build-for-testing 失败）；`start-wda.sh` 签名/UDID 自动获取 |

## 部署

- 平台已用 `./deploy-test.sh`（一键）部署到 HK 测试服务器：`https://hk.hsddns.com`（nginx → 127.0.0.1:8790，systemd `whatsapp-ai.service` / `whatsapp-connector.service` 均 active）
- 迁移已验证：`vpn_ip` 列移除；`uq_mobile_devices_tenant_udid` 唯一索引（历史重复 (tenant_id,udid) 先收敛再建索引，回归测试 `TestMigrateDedupesDuplicateUdid`）
- 本地网关已在 Mac（本机）运行：Web `http://localhost:8300/`，云通道 `wss://hk.hsddns.com/api/ios-agent/v1/gateway/ws`

## 端到端验证（真实 iPhone + WDA 192.168.20.33:8100）

1. 签发网关凭证 `macmini-01` → 网关登录 → 平台「组网」页网关在线（heartbeat 更新 last_seen_at）✓
2. 网关 `device_list` → 平台按 (tenant_id,udid) upsert：`controllerId=macmini-01`、`status=online`、`wdaUrl=http://192.168.20.33:8100`、iOS 15.8.7 ✓
3. 建群发任务 → `pushed=true` → 网关执行 → `item:result` 落库 → 任务 done ✓（本机 WhatsApp 未安装，发送结果为 `failed`，错误即真实原因）
4. 取消任务：执行中 item → 结果保留，未执行 items → cancelled，任务 → cancelled ✓
5. 断线重连：平台重启后网关自动重连并补报本地已持久化结果（at-least-once，幂等）✓

## 已知限制 / 后续

- **测试机未安装 WhatsApp**（`FBSApplicationLibrary returned nil for "net.whatsapp.WhatsApp"`）：完整"真发送"需在 iPhone 安装并登录 WhatsApp 后复测（发送链路本身已通）。
- **网关实现语言**：设计 P3 为 Go 重写；本次为控制风险沿用 P0 Python 原型并补齐新协议（WDA 激活/看护/构建逻辑成熟可复用）。Go 版网关（`cmd/gateway` + `internal/{session,executor,watcher,web}`）列为下一增量，迁移边界见设计 §7.2。
- easytier 保持可选、默认关闭（v1 主链路纯 WSS，出现真实失败模式后再按 ADR 引入）。
- 手机侧 enroll/config/status 旧接口（P5 停用）本次未删除，仅手机不再自报。

## 访问入口

- 云平台（管理端，含「组网」页）：`https://hk.hsddns.com`
- 本地网关 Web：`http://localhost:8300/`（`GET /api/cloud` 看连接状态）
