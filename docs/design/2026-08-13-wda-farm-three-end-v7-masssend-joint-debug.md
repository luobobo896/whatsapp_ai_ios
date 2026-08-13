# 三端串联 v7 实施记录：群发（按手机号 / 不传手机号）真机联调（2026-08-13）

> 对应设计：`docs/design/2026-08-13-wda-farm-three-end-architecture.md`（v6）
> 承接 v6（`2026-08-13-wda-farm-three-end-implemented.md`）：本轮把群发真正跑通到真机发送，
> 并补齐「不传手机号」模式与 WhatsApp Business 支持。

## 结论

三端群发已端到端跑通（平台 → 网关 → 手机 WDA → WhatsApp Business 真实发送，结果回传落库）：
- **按手机号发送**：任务带号码 → 发送成功（`sent`）。
- **不传手机号**：任务不带号码 → 发送到当前/最近会话（`sent`）。
- **未安装 WhatsApp 的手机**：明确失败（`failed: whatsapp not installed`），不会假成功。

## 联调关键发现（真实环境证据）

1. **两台测试机均无普通 WhatsApp，其中一台（192.168.20.111，iOS 15.8.8）装有 WhatsApp Business**
   （bundle id `net.whatsapp.WhatsAppSMB`）；另一台（192.168.20.33，iOS 15.8.7）两个版本都没有。
   - 原有代码硬编码 `net.whatsapp.WhatsApp`，在 Business 手机上必然建会话失败。
2. **iOS 15.8 上 WDA `/session/:id/url` 深链不可用**：
   - 带 bundleId：`Device does not have the capability to open an application with a url`
   - 不带 bundleId：`Device does not have the capability to open the default app from a url`
   - 该能力需要 iOS 16.4+（`XCTRunnerDaemonSession openURL:usingApplication:`）。
   - 因此「按手机号」无法依赖 `whatsapp://send?phone=` 深链，必须走 UI 兜底。
3. **发送按钮选择器需校准**：WhatsApp Business 中文版发送键 accessibility id 为
   `ChatBar_SendButton`（label「发送」），原候选（`Send`/`发送`）都匹配不到。
4. 测试机 WhatsApp 只有单个号码会话（+86 176 8854 0775，设备自己的“你的消息”会话），
   「按手机号」与「不传手机号」最终都发到该会话，符合预期。

## 各端改动

### 本地网关 `whatsapp_ai_gateway`（main-test，已提交 d5b0f83）
- `gateway/wda.py`：
  - WhatsApp bundle 自动识别：候选 `net.whatsapp.WhatsApp` → `net.whatsapp.WhatsAppSMB`，
    首个建会话成功者生效；设备配置可 `whatsapp_bundle_id` 显式覆盖（executor 透传）。
  - `send_message` 双模式：
    - 按号码：先试深链（iOS 16.4+ 生效）；失败（iOS 15.8）回退到聊天列表按号码匹配
      （解析 accessibility 树，cell name 去非数字 == 目标号码 → 点该会话）。
    - 无号码：当前已有打开的会话则直接发送，否则点聊天列表第一个真实会话
      （跳过筛选/工具行，识别 `WAChatSessionCell_Message`）。
  - 发送按钮候选新增 `ChatBar_SendButton`、`label == '发送'`；新增聊天列表返回键候选。
- `gateway/executor.py`：把设备 `whatsapp_bundle_id` 透传给 `send_message`。

### 云平台 `whatsapp_ai`（main-test，已提交 dc94fa0，已部署 HK 测试服务器）
- `internal/store/mobile_broadcast.go`：`CreateMobileBroadcastTask` 允许不传手机号——
  空号码列表生成 1 条空号码明细（`total=1`，发送到当前/最近会话），不再报 `broadcast phones empty`。
- `frontend/src/views/IOSDevicesView.vue`：群发对话框手机号可留空（提示“不填则发送到当前/最近会话”），
  移除“至少一个手机号”硬校验；成功/离线提示适配 0 条手机号文案。
- 测试：新增 `TestMobileBroadcastTaskWithoutPhone`（空号码建任务 → 1 条空号码明细 → sent → done）；
  存量 broadcast/mobile 相关 Go 测试 + 前端 182 用例全部通过。

### 手机 WDA `WhatsAppDeviceAgent`
- 无代码改动（WDA 能力即通用 UI 自动化，发送逻辑全部在网关侧）。

## 部署

- 平台：`./deploy-test.sh` 部署到 HK 测试服务器（`https://hk.hsddns.com`），
  备份 `/var/backups/whatsapp_ai/20260813T102649Z`，服务 active、`/health/ready` ok。
- 网关：本机重启（tmux session `gateway`，`:8300`），云通道已重连并健康上报两台设备。

## 端到端验证（真实 iPhone，商品类文案，无风险字眼）

| 任务 | 设备 | 模式 | 结果 |
|---|---|---|---|
| `9b8457dd` 内容「【限时秒杀】香脆坚果礼盒…」 | .111（Business） | 按手机号 8617688540775 | `sent`，11089ms |
| `9e0fe649` 内容「【新品上市】便携咖啡手冲壶…」 | .111（Business） | 不传手机号 | `sent`，10603ms |
| `b29cf727` | .33（无 WhatsApp） | 按手机号 | `failed: whatsapp not installed (tried: net.whatsapp.WhatsApp, net.whatsapp.WhatsAppSMB)` |

- 手机侧复核：两条商品文案均已进入 +8617688540775 会话（18:28，状态已发送），截图前 UI 树可查。
- 平台侧任务均转 `done`，明细状态/耗时/错误正确回传。

## 已知限制 / 后续

- **iOS 15.8 无深链**：按手机号仅能发给聊天列表中已存在的号码；陌生号码需先在手机上产生会话
  （或换 iOS 16.4+ 设备走深链）。建议后续在「新聊天→搜索→无结果」场景明确报错提示。
- 测试机 WhatsApp 为 **Business 版**（`net.whatsapp.WhatsAppSMB`）；普通 WhatsApp 设备由自动识别覆盖，
  但选择器（尤其发送键）仍需按普通版再校准一次。
- 首次发送测试时误用过含「群发」字样的文案（已发 1 条到测试号自己的会话，v6 遗留环境），
  已按用户要求全部改用商品类话术；后续测试文案固定为商品推广风格。
- 网关 `devices.json` 含本机运行时状态（凭证 token、设备 health），未提交，保持本地。
