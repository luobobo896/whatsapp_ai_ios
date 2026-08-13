# 三端串联 v11 实施记录：P2-10 WDA 掉线根因 + P2-8 soak/压测 + P0-3 深链边界 + P2-11 AI 费用监控（2026-08-13）

> 承接 v10。本轮按交付评估缺口清单把剩余项全部推进：
> P0-3（iOS 16.4+ 深链）、P2-8（soak/压测）、P2-10（WDA 掉线根因）、P2-11（费用/额度监控）。

## 结论

### P2-10 测试机 WDA 掉线根因（已定位，可修部分已修复）
- **设备 .33（5060c403…，192.168.20.33）**：`ping` 100% 丢包、`ioreg` 无 USB 设备 =
  **物理离线**（拔线/断电/Wi-Fi 断开）。旧看护逻辑每 30s 对它执行一次 xcodebuild 重激活
  （必然失败）→ 日志刷屏 + 「WDA 反复掉线」观感。
- **修复**（网关 f61bd43）：`usbConnected()`（ioreg）+ `reactivateDecision` 纯函数——
  网络不可达且未接 USB 时跳过重激活，last_health.error 改为明确提示「重连 USB/Wi-Fi」，
  仅状态翻转时告警。修复后日志不再增长（1689 行稳定）、无 xcodebuild thrash。
- **设备 .236（59524996…）**：USB 在线，看护按新决策正常重激活（23:35/23:42 两次，
  均恢复在线）；8 分钟 ping+WDA 双通道分类监控全程 `ping=ok,wda=ok`，未见瞬时闪断。
  其偶发掉线初步归因为 WDA Runner 会话/前台状态波动，待长时间观察；USB 在线的设备
  现在可自动自愈。
- **用户待办**：.33 需要物理重连（USB 或 Wi-Fi）；重连后看护会自动恢复。

### P2-8 网关 soak/压测（已做）
- `go test -race ./...` 全绿（含新增压测）。
- 新增 `TestExecutorStressQueue`（50 任务 × 10 条，并发 Submit/Cancel，结果 500/500
  不丢不漏——顺带修复了测试暴露的 ReportQ 背压死锁模式：结果回收必须先于入队）与
  `TestExecutorStatusConcurrency`（8 协程并发状态快照）。
- 实机 soak：网关连续运行监测 ~8 分钟云通道 `connected=True` 全程、日志零增长、
  RSS 稳定 4.1MB（3 次采样一致）；此前今日已历经 3 次 HK 部署重启窗口均自动重连。

### P0-3 iOS 16.4+ 深链（无 16.4+ 真机，以代码+提示闭环）
- 代码路径复核：`openTargetChat` 深链成功（iOS 16.4+）→ 非新会话直发；失败（<16.4）
  → 聊天列表按号码 → 新聊天搜索兜底 → 明确报错「deep link unsupported and no
  chat/contact for X」。
- 前端新增降级提示（082a3d1）：设备 iOS < 16.4 时群发弹窗提示「不支持陌生号码深链，
  仅能发送聊天列表中已有会话的号码」。真机 16.4+ 复测仍需 ≥16.4 设备（硬件待备）。

### P2-11 费用/额度监控（需求一 模块三，最小可用版已上线 HK）
- **计量**：`ai_usage_daily` 按账号/租户按天幂等聚合（connector 上报的 ModelUsage 落账）。
- **预算与超额暂停**：租户可设日 Token 预算 + 「超额自动暂停 AI 回复」；
  预调用门禁（`/api/internal/conversations/query` 新增 `BudgetPaused`）在生成/发送前
  抑制 AI 回复，connector 识别跳过（不产生已发送但无历史的分裂状态）。
- **告警**：当日首次超预算写 `tenant_alerts`（同日幂等）。
- **管理端**：平台租户页新增「今日Token/预算」列（占比标签/超额暂停标签）+ 预算设置弹窗；
  `GET /api/platform/usage` 平台看板。

## 各端改动 / 提交

- 平台 `whatsapp_ai`（feat/broadcast-template-export）：e52826c（AI 费用监控）、
  082a3d1（iOS<16.4 提示）；迁移见 `docs/database/2026-08-13-broadcast-template-export.sql`
  第 6 节；HK 备份 `20260813T154312Z`，`/health/ready` ok，迁移已核验
  （ai_usage_daily 8 列、tenants 预算 3 列）。
- 网关 `whatsapp_ai_gateway`：f61bd43（watchdog 防 thrash + soak/压测用例）；
  本机已重建重启，云通道正常。

## 验证证据

| 项 | 证据 |
|---|---|
| 平台测试 | `go test ./...`（含真实 PG 集成：AI 用量聚合/预算门禁/告警幂等/看板）；仅 2 个已知存量失败 |
| 前端测试 | 191 用例通过；`pnpm build` 通过 |
| 网关测试 | `go test -race ./...` 全绿；压测 500 条结果不丢不漏 |
| 迁移核验 | HK psql：ai_usage_daily/tenant_alerts/tenants 预算列齐全 |
| 网关 soak | 8 分钟 connected=True、日志零增长、RSS 稳定 4.1MB |
| .236 分类监控 | 8 分钟 ping=ok,wda=ok 全程 |
| .33 根因 | ping 100% 丢包 + ioreg 无 USB = 物理离线 |

## 已知限制 / 后续

- 「费用」当前只计 Token 账本（用量），未接入单价/账单（需求 1.18 费用报表+导出留待后续）。
- 租户视角用量接口（`/api/platform/usage` 为平台管理员视图）已在后端就绪
  （HandleTenantAIUsageAndAlerts），租户侧前端展示页未做（看板 UI 后续）。
- .236 偶发 WDA 掉线在 USB 在线时可自动自愈；彻底根因（iOS 后台挂起 WDA Runner？）
  建议用 Xcode 设备日志长时间抓取定位。
- 缺口清单剩余：仅「iOS 16.4+ 真机复测」需硬件支持。
