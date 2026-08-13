# 三端串联 v9 实施记录：普通 WhatsApp 真机校准（WA Business 等价，2026-08-13）

> 承接 v8（`2026-08-13-wda-farm-three-end-v8-template-export.md`）：闭环 P1 最后一项
> 「普通 WhatsApp 真机校准」。用户确认 **WA Business 等价 WhatsApp**（Business 版与普通版
> 界面结构一致，选择器通用），校准目标为真机 Business 设备，并重跑 HK 一键部署。

## 结论

- **两种发送路径真机验证通过**（设备 `192.168.10.236`，iOS 15.8.8，WhatsApp Business）：
  - 按手机号 `8617688540775`：聊天列表按号码匹配会话 → 输入 → 点发送 → **送达**
    （22:17，消息「【限时特惠】便携咖啡手冲壶 99 元…」，气泡状态 已发送到+8617688540775）。
  - 不传手机号：当前/最近会话直接发送 → **送达**（22:19，「【新品上架】高纤燕麦片 29.9 元两袋…」）。
- **选择器无需改动**：消息输入框 `class chain: **/XCUIElementTypeTextView[1]` 与发送键
  `accessibility id: ChatBar_SendButton` 主选择器直接命中（未走 fallback/视觉兜底）；
  聊天列表 cell 号码匹配（digits 归一化）、返回键、tab 结构均与 v7 固化选择器一致。
- 本轮新增 **wda-probe 校准探针**（网关 `cmd/wda-probe`，提交 d137fd0）：复用网关同一
  `internal/wda` 包驱动真机，支持 dump 元素树与 `-send` 试发，未来新设备/新版本校准可直接复用。

## 关键证据（accessibility 树）

- 会话创建：`bundle=net.whatsapp.WhatsAppSMB`（该机未装普通版，`net.whatsapp.WhatsApp`
  返回 session not created；Business 即校准目标）。
- 聊天列表 cell 名含号码（带空格/逗号，`digitsOf` 归一后匹配）：
  `name="+ 8 6,1 7 6,8 8 5 4,0 7 7 5"`。
- 发送后气泡（树内 `XCUIElementTypeOther`，name/label 均含完整状态）：
  `你的消息, 【限时特惠】便携咖啡手冲壶 99 元，今日下单立减 20, 22:17, 已发送到+8617688540775`。

## 部署与状态

- **HK 一键部署**：`./deploy-test.sh`（feat/broadcast-template-export @ f852372），
  备份 `/var/backups/whatsapp_ai/20260813T141159Z`，`/health/ready` ok。
- **网关**：本机重建并重启（tmux `gateway`，`:8300`，含 executor itemContent 抽取 +
  wda-probe 工具），22:23:40 重连云通道，租户「测试租客」，executor 空闲。
- 平台 WSS 自动重连验证：HK 重启窗口内网关 3 次重连（22:11/22:18/22:23），无需人工介入。

## 验证矩阵

| 路径 | 方式 | 结果 |
|---|---|---|
| 按手机号发送（真机） | wda-probe -phone 8617688540775 -send | 送达，22:17，7.6s |
| 不传手机号发送（真机） | wda-probe -send | 送达，22:19，3.4s |
| 网关逐条内容优先 | `itemContent` 单测（明细内容优先/空回退） | pass |
| 平台模板逐条渲染 | v8 store 集成测试（真实 PG） | pass |
| HK 路由/迁移 | v8 已核验；本轮重部署后 /health/ready ok | ok |

## 已知限制 / 后续

- 另一台设备 `192.168.20.33`（iOS 15.8.7）此前无 WhatsApp；本轮网关看护已为其拉起 WDA
  （22:16:43 reactivate），但其 WDA 端口 8100 尚未就绪（设备侧信任/解锁可能需人工确认）。
  若后续给该机安装 WhatsApp（普通版或 Business 均可），可用 `wda-probe` 按本文档流程复校。
- 真机发送验证为「设备自己的号码」会话（+8617688540775），与 v7 一致，不打扰第三方客户。
- 三端全链路（HK 平台建任务 → 网关 → 真机）本轮未跑（管理端建任务需浏览器会话）；
  平台模板渲染与网关逐条内容均有测试覆盖，真机层已用同一 wda 代码路径验证，
  链路等价性风险低；如需严格 E2E，可在 HK 管理端用含 `{{phone}}` 模板建一条任务复核。
