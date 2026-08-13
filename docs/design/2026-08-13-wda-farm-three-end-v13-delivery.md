# 三端串联 v13 实施记录：商业交付收尾（邮件告警 + 余额显示 + 网关登录 + 群发路径升级 + UI 优化，2026-08-14）

> 承接 v12。按用户要求做商业交付收尾（iOS 16.4+ 真机复测除外）：
> 网关管理页登录/登出、租户/平台级邮件告警、默认余额显示、设备群发路径升级
> （全部/网关/单设备 + 客服联系人号码来源）、三端 UI 优化。

## 结论

### 网关 Web 管理页登录/登出（本机已生效）
- `devices.json` 增 `web.password`：设置后 `/api/*` 全部要求会话；登录签发 12 小时
  HttpOnly cookie，登出即时撤销；未设置密码 = 开放模式（前端提示风险）。
- 前端：登录弹层（密码框/错误提示）、header 登出按钮、`api()` 统一包装 401 自动跳登录、
  启动时 `/api/session` 检查。本机已生成管理密码（见 devices.json）。
- 实测：未登录 401 → 登录 200+cookie → 带 cookie 200 → 登出 200 → 401。

### 设备群发路径升级（已部署 HK，前端 196 用例）
- 群发组设备范围三选一：**全部设备 / 按网关（下拉展示网关名下设备数与在线态）/ 指定设备**
  （`resolveBroadcastDeviceIds` 纯函数解析 + 5 单测）。
- 手机号来源：手动填写 + **从客服账号联系人选取**（`/api/accounts/:id/contacts` 勾选合并，
  单设备与多设备群发均支持）。

### 邮件告警（租户级 + 平台级，已部署 HK）
- `internal/mail`：SMTP 发送器（`SMTP_HOST/PORT/USER/PASSWORD/FROM` + `ALERT_EMAIL`
  平台收件人；未配置降级仅日志）+ 分发器（每 30s 扫描未发送 `tenant_alerts` →
  收件人 = 租户管理员（owner/admin）+ 平台邮箱去重 → 发送 → 标记 `emailed_at`；
  无 mailer 时标记跳过防重复扫描）。
- 覆盖：AI 预算超标、客服账号掉线（connector 写入）、服务器过载（`HEAP_ALERT_MB`
  默认 4096，超阈值告警、回落自动复位）。

### 默认余额显示
- 平台看板/租户卡片/租户列表默认展示「剩余预算余额」（预算-已用，负数红色超额）：
  `PlatformAIUsageRow.BalanceTokens`、`GET /api/ai-usage` 返回 `balanceTokens`。

### UI 优化
- 网关管理页：新增「历史发送（按天归档）」面板（最近 14 天，重启不丢）+ stats 小屏响应式。
- 平台：看板「剩余余额」列、租户余额卡片样式统一（success/danger 语义色）。

## 提交与部署

| 仓库 | 分支 | HEAD | 说明 |
|---|---|---|---|
| whatsapp_ai | feat/broadcast-template-export | c4a9f40 | 0059c9a(群发路径) + f7437ab(邮件/余额) + 评估文档 |
| whatsapp_ai_gateway | main-test | c89bb9b | 488dfdb(登录) + c89bb9b(历史面板) |
| WhatsAppDeviceAgent | main-test | 已推送 origin | v11/v12 记录 |

- HK：`./deploy-test.sh` 备份 `20260813T161852Z`，`/health/ready` ok，
  `tenant_alerts.emailed_at` 迁移已核验，HEAD=f7437ab。
- 网关：本机重建重启（00:18:47 云通道重连），登录/登出与历史面板实测可用。

## 待办 / 说明

- SMTP 上线：在 HK `/etc/whatsapp-ai.env` 配置 `SMTP_HOST/SMTP_PORT/SMTP_USER/SMTP_PASSWORD/
  SMTP_FROM/ALERT_EMAIL` 后邮件告警即生效（当前未配置=仅日志）。
- 网关管理密码在 `devices.json`（web.password），可自行修改；修改后需重启网关。
- 唯一未闭环项：iOS 16.4+ 深链真机复测（需 ≥16.4 硬件，用户确认暂不动）。
