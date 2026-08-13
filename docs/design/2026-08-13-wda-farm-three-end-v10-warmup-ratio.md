# 三端串联 v10 实施记录：智能调度补全（账号预热 + 新会话占比控制）+ 真机批量验证（2026-08-13）

> 承接 v9（真机校准）。闭环交付评估缺口清单 P0-1「智能调度」剩余两块（预热/占比控制）
> 与 P0-2「批量验证：连续 10 条成功率 ≥90%」。

## 结论

- **账号预热**（需求二 2.8「新账号分阶段放量」）：设备级按天放量——第 1 天 5 条、每日 +10、
  稳态 40 条/天（参数可配）。网关按 `metrics.json` 的活跃天数计算当日上限，达标即停任务、
  剩余明细标 cancelled（原因「预热控制：…请明日继续」）并上报 device:status。
- **新会话占比控制**（「新会话不超过 30%，超额次日再发」）：网关在发送前识别该号码是否为
  新会话（聊天列表无既有会话、经「新聊天→搜索」打开），当日新会话占比超上限则该条标 failed
  （原因「新会话占比控制：…请明日再发」，**不计入连续失败熔断**），存量会话不受影响继续发送。
- **真机批量验证**：同一设备连续 10 条商品类文案全部发送成功并送达（100% ≥ 90%）。

## 各端改动

### 云平台 `whatsapp_ai`（feat/broadcast-template-export @ b0908cc，已部署 HK）

- 模型/迁移：`BroadcastSchedule` 增 `warmUpEnabled/warmUpStartCap/warmUpDailyStep/warmUpSteadyCap`
  与 `maxNewSessionRatio`（任务与群发组表同 5 列；默认 5→+10→40 条/天、占比 30%）。
- store：`normalizeBroadcastSchedule` 统一默认值（占比负数→30、0=显式不限制）；
  任务/组创建与扫描贯通；导出 CSV 概览新增「账号预热 / 新会话占比上限」。
- device:status 业务异常前缀扩展：`熔断 / 预热 / 占比` 均落设备 abnormal 事件（日志弹窗可查）。
- 前端：单设备/多设备群发表单新增预热开关（起步/日增/稳态）与新会话占比（0-100%），随
  schedule 下发；测试用例同步。
- 测试：预热参数任务/组往返与默认值归一集成测试（真实 PG）通过。

### 本地网关 `whatsapp_ai_gateway`（main-test @ 799725f，本机已重建重启）

- `internal/wda/whatsapp.go`：拆分 `OpenChatForSend`（返回会话 id + isNew）与 `TypeAndSend`；
  `SendMessageToPhone/WithAssist` 保持原签名兼容（平台 wda.RunTask 不受影响）。
- `internal/gateway/executor.go`：
  - 预热：每任务循环前按 `daysActive()`（历史归档天数+1）与 `warmupDailyCap` 校验今日计数，
    达上限 → 剩余明细标 cancelled + device:status「预热控制：…」。
  - 占比：`newSessionRatioExceeded`（整数百分比比较）在发送前决策，超额明细标 failed
    （`strings.Contains("占比控制")` 跳过熔断计数）。
  - metrics：`Metrics.NewSessions` 计入今日统计、跨天归档、`/api/metrics` 汇总。
- 测试：`warmupDailyCap`/`newSessionRatioExceeded`/新会话计数与跨天持久化单测通过。

### 手机 WDA

- 无代码改动。

## 部署

- 平台：`./deploy-test.sh` → HK，备份 `/var/backups/whatsapp_ai/20260813T144514Z`，
  `/health/ready` ok；迁移核验：任务/群发组各 5 个新列均存在。
- 网关：本机重建重启（22:44:37），云通道重连成功、executor 空闲。
  - 注意：网关仓库另有未提交的 `cloud.go`/`README.md`（断线指数退避重连等改进，非本轮产出），
    已在运行中的二进制内但未提交，请确认后自行提交。

## 真机批量验证（P0-2）

- 设备 `192.168.10.236`（iOS 15.8.8，WhatsApp Business），目标为设备自身号码会话
  （+8617688540775，与 v7/v9 同一会话，不打扰第三方）。
- `wda-probe` 连续发送 10 条商品类文案：**10/10 SEND OK**；WDA 树复核 10 条全部在会话中
  （第 1-10 批均 found）→ 成功率 100%。

## 已知限制 / 后续

- 预热「活跃天数」自 metrics 落盘启用日起算（网关本地历史）；重装/清盘会重置阶段，
  属保守行为（回到低配额，不会超发）。
- 占比控制的「次日再发」以明细 failed + 明确原因落地，运营需次日重建任务补发；
  平台侧自动「次日自动续发」队列留待后续。
- 陌生号码无既有会话时，占比控制与「新聊天→搜索」兜底叠加生效；iOS 16.4+ 深链场景
  的 isNew 判定为 false（深链打开视为存量路径），待 iOS 16.4+ 真机复测确认。
- 需求一「费用/额度监控」仍在缺口清单（P2-11），尚未开发。
