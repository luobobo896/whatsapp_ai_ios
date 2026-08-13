# 三端串联 v12 实施记录：运营看板 + 费用报表导出 + 账号掉线预警（需求一 模块一/三收尾，2026-08-13）

> 承接 v11（P2-11 AI 费用计量/预算门禁已上线）。本轮把需求一「智能预警体系」的
> 展示/导出/账号掉线预警补齐，并把网关 main-test 全部未推送提交推送到 origin。

## 结论

- **平台运营看板**（需求一 1.19）：平台管理员总览页新增「AI 费用看板」——每租户
  今日 Token/调用次数/日预算/预算占比/超额暂停标签，一键导出费用报表 CSV。
- **租户用量视图**（需求一 1.14/1.16 租户可见）：租户总览页新增「AI 用量与告警」卡片
  （今日 Token/调用/日预算 + 最近告警列表）；总览指标卡新增「今日 AI Token」。
- **费用报表导出**（需求一 1.18）：`GET /api/platform/usage/export?days=N`（1-90 天）
  按租户×账号×天输出 CSV（UTF-8 BOM，Excel 直接打开）。
- **账号掉线预警**（需求一 模块一）：connector `RecordDisconnect` 落掉线历史的同时写
  `tenant_alerts`（类型 `account_disconnected`，10 分钟内同账号去重；表缺失仅告警不阻断，
  兼容 connector 先于平台迁移启动）。

## 各端改动

### 云平台 `whatsapp_ai`（feat/broadcast-template-export @ 3859d9d，已部署 HK）
- store：`AIUsageExport`（租户×账号×天明细，≤90 天）。
- handler：`HandlePlatformAIUsageExport`（CSV）、`HandleTenantAIUsageAndAlerts`
  路由化（`GET /api/ai-usage`，RequireActiveTenant）。
- 路由：`/api/platform/usage/export`（平台管理员）。
- connector：`RecordDisconnect` 追加租户掉线告警（幂等去重）。
- 前端：`Overview.vue` 平台看板卡片 + 租户用量卡片 + 指标卡；`Overview.test.js`
  适配（api mock + 表格桩 row 作用域）。
- 测试：`TestAIUsageExport` 集成测试；前端 191 用例、Go 全量（除 2 个已知存量失败）。

### 本地网关 `whatsapp_ai_gateway`
- 无代码改动；**main-test 全部 37 个本地提交已推送到 origin**
  （`0bd77e9..72d50f7`，含 cloud 断线自愈系列 8350afe/6a3cffb/72d50f7、watchdog 防 thrash、
  wda-probe、executor 智能调度/逐条内容等）。devices.json 保持本地不提交（含运行时凭证）。

## 部署

- HK：`./deploy-test.sh`，备份 `/var/backups/whatsapp_ai/20260813T160100Z`，
  `/health/ready` ok；新路由冒烟：`/api/platform/usage`、`/api/platform/usage/export`、
  `/api/ai-usage` 均 401（鉴权正常挂载）。HK HEAD = 3859d9d。

## 已知限制 / 后续

- 费用仍为 Token 账本（未接单价/账单金额）；「运营看板」的服务器资源曲线与账号在线率
  曲线（需求一 1.19 完整版）依赖服务端 metrics 采集，后续可接 prometheus 或网关 metrics。
- 租户告警目前仅 AI 预算与账号掉线两类；服务器过载告警（模块二）留待后续。
- 缺口清单业务项全部闭环；仅剩「iOS 16.4+ 真机复测」需硬件。
