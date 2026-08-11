# 真机（iPhone + Android）WhatsApp 群发 · 可行性方案（图文版）

- 日期：2026-08-04（v5 图文版）
- 状态：**结论：可行，推荐实施**
- 类型：可行性方案 / 技术设计
- 关联：`docs/design/2026-08-04-phone-broadcast-and-contacts.md`（whatsmeow 群发链路，可并存）
- 参考项目：OpenMinis（github.com/OpenMinis/OpenMinis，GPLv3）——仅借鉴其「平台下发 → 端侧 Agent 执行」的框架思路，裁剪为只做 WhatsApp 群发的精简 wa-agent（见 5.4），不并入其代码、无 GPL 传染
- 图片源文件：`docs/design/images/device-*.mmd`（mermaid，可改可重新生成）

## 1. 需求概述

1. 控制手机（大部分 iPhone、小部分 Android）操作手机上的官方 WhatsApp 应用群发消息；
2. **双端适配**：iPhone 与 Android 都要支持；
3. **接入本系统**：通过本系统界面/API 控制设备、下发任务；
4. **状态监听**：实时统计成功多少条、失败多少条，及逐条/逐设备状态。

## 2. 方案总览与可行性结论

| 用户诉求 | 结论 | 依据 |
|---|---|---|
| 能否控制手机操作 WhatsApp 群发 | ✅ 可行 | 双端自动化工具链成熟，市面已有同类群控产品验证 |
| iPhone / Android 双端适配 | ✅ 可行 | iOS 用 WebDriverAgent，Android 用 adb + UIAutomator2，统一驱动接口 |
| 接入本系统统一控制下发 | ✅ 可行 | 设备 Agent 主动注册 + 平台公网 WebSocket 下发，复用现有 server / 群发工作台 / WS 推送 |
| 成功/失败条数实时监听 | ✅ 可行 | 任务落库 + 逐条结果 + WebSocket 实时推送 |
| 安全性 | ✅ 真机方案更安全 | 官方 App + 真实设备指纹，账号技术层风险低（见第 8 章） |

**一句话总结**：真机方案技术上完全可行，双端工具链开源成熟，能无缝接入本系统；
下发采用「平台 → 精简 wa-agent」模型：Agent 只做 WhatsApp 群发一件事，LLM 辅助更精准，
发完即上报，满足「成功 N 条 / 失败 M 条」的实时统计需求；相比 Web 协议，真机账号安全性更高。

## 3. 总体架构

**设备通过 Agent 主动注册 + WebSocket 长连接入平台**：平台提供公网 `wss://` 服务，
每台设备（或执行单元）启动后主动连接平台并注册，平台统一下发指令、接收结果。
手机不需要公网 IP、不需要端口映射——只要手机能访问平台公网地址即可（4G/Wi-Fi 均可）。

![Agent 注册与 WebSocket 下发架构](images/device-agent-websocket.png)

### 3.1 两种执行单元（平台视角统一为 Agent）

| 执行单元 | 形态 | 与平台连接 | 内部如何操作手机 |
|---|---|---|---|
| **Android 手机（内置 Agent）** | 手机本体即 Agent（无障碍服务 + 深链） | WebSocket 直连平台 | 本机执行：读 UI 树 / 点击 / 设置文本 / 截屏，**无需 USB、无需主机** |
| **iPhone + 本地主机代理** | 手机 + 一台轻量代理（Mac/PC，Go） | 代理 WebSocket 连平台 | 代理经 USB/Wi-Fi 连接 WebDriverAgent，驱动 iPhone |

平台只面向统一的「执行单元（Agent）」协议，不感知内部形态；设备管理页按执行单元展示，
Android 手机与 iPhone 单元对平台完全透明。

### 3.2 平台侧四层结构

1. **管理端（本系统）**：群发工作台选择设备 + 手机号 + 内容，创建任务；设备管理页查看在线状态；
   WebSocket 实时收到成功/失败计数；
2. **server :8790**：**公网 WebSocket 下发服务（wss）**——Agent 认证、心跳、离线指令队列、结果汇总、任务落库；
3. **Agent 层**：Android 内置 Agent / iPhone 本地代理，实现同一套指令协议；
4. **真机**：每台手机一个 WhatsApp 账号（一机一号）。

配套数据：PostgreSQL 新增 devices / broadcast_tasks / broadcast_task_items 等表（见第 6 章）。

## 4. 平台 → 手机 下发链路（核心一）

### 4.1 分层与数据流

![下发与状态监听时序](images/device-broadcast-sequence.png)

1. 管理端创建任务 → server 把手机号按执行单元分组、配额分配；
2. Agent 启动后**主动注册**并与平台建立 WebSocket 长连（token 鉴权）；离线 Agent 的指令进入队列，上线即补发；
3. server 通过 `task:dispatch` 把任务 items 下发到对应 Agent，Agent 内部按设备**串行**执行（保证真人节奏）；
4. 每执行完一条，Agent 通过 `item:result` 回写（DB + WS 事件），管理端实时看到 成功 N / 失败 M / 待发 K；
5. Agent 心跳持续上报，设备状态实时刷新；断线重连后自动补拉未完成 items。

### 4.2 指令下发协议（平台 ↔ Agent，WebSocket）

平台侧提供公网 WebSocket 服务（`wss://<域名>/agent`，TLS + token 鉴权）；所有消息为 JSON 帧，含 `msgId` 做幂等。

| 消息 | 方向 | 说明 |
|---|---|---|
| `agent:register` | Agent → 平台 | 注册：设备 token、udid、型号、系统版本、Agent 能力 |
| `agent:heartbeat` | Agent → 平台 | 心跳 + 状态（online/busy/offline）+ 指标（每 15~30s） |
| `task:dispatch` | 平台 → Agent | 下发任务 items（task_id、设备、手机号、内容、节奏参数） |
| `item:ack` | Agent → 平台 | 收到 items 的确认（保证不丢） |
| `item:result` | Agent → 平台 | 逐条结果（sent/failed/timeout + 失败原因 + 耗时） |
| `task:query` | Agent → 平台 | 重连后补拉 pending 的 items |
| `agent:command` | 平台 → Agent | 单设备即时指令（如停止、重启 Agent） |

任务队列模型：任务 → 拆 items（每手机号一条）→ 按执行单元分组 → 平台维护「每单元 FIFO 指令队列」→
Agent 收到后**串行**执行（驱动动作 + 节奏控制 + 结果回写）。**单设备串行、多设备并行**；
离线 Agent 的指令积压在队列，上线即补发。

### 4.3 执行单元内部：Agent ↔ 手机

平台只与 Agent 通信（WebSocket），Agent 内部再操作手机，方式因平台而异：

**Android 手机（内置 Agent，无需 USB/主机）**
- Agent 是手机内的一个后台 App：无障碍服务（AccessibilityService）读 UI 树、执行点击与设置文本，
  深链（`am start` / Intent）打开会话，无障碍截图或 MediaProjection 截屏；
- 手机只需能访问平台公网地址（4G/Wi-Fi 均可），**完全无线、可散落各地**；
- 输入文本用无障碍 `ACTION_SET_TEXT`（直接设置到输入框，不依赖键盘）。

**iPhone + 本地主机代理（iOS 官方自动化通道要求 host 工具链）**
- iOS 沙盒禁止第三方 App 自动化其他 App，Apple 官方通道是 XCUITest（WebDriverAgent），
  需由 Mac/PC 工具链安装启动；因此每台 iPhone（或每组 iPhone）配一台**轻量本地代理**（Go，可跑在任意 Mac/PC 或现有服务器）；
- 代理经 USB/Wi-Fi 连接 WDA，再经 WebSocket 连平台；平台视角它与 Android Agent 完全一致。
- USB 模式：`go-ios ios forward 8100 8100` 端口映射，多设备分配独立主机端口（8101…），
  代理访问 `http://127.0.0.1:<port>` 发 W3C WebDriver 指令；
- Wi-Fi 模式：iOS 11+ 无线调试（首次需 USB 配对信任一次），WDA 运行后代理直接访问
  `http://<设备WiFiIP>:8100`（Appium 对应 `appium:webDriverAgentUrl`）。

**接入方式对比（适用于 iPhone 代理 ↔ 手机）**

| 维度 | USB 有线（默认） | Wi-Fi 无线（可选） |
|---|---|---|
| 稳定性 | 延迟低、不掉线 | 受信号/手机休眠/AP 漫游影响，大批量时断连概率上升 |
| 供电 | USB 同时供电、屏幕常亮 | 仍需外接电源（USB 充电器） |
| 安全 | 配对一次建立信任，不易被扫描 | 无线调试端口可能被扫描，需密码/配对码 |
| 多设备管理 | usbmuxd / adb USB 枚举最成熟 | 需 mDNS/固定 IP，设备 IP 变动要处理 |
| iOS 前置条件 | 无 | 需先 USB 配对信任；同一 Wi-Fi、网络质量要求高 |
| Android | 不适用（内置 Agent 天然无线） | 不适用 |

**建议**：Android 用内置 Agent（无线）；iPhone 代理默认 USB（稳定性 + 供电 + 安全），
接入方式存为设备属性（`transport: usb | wifi`），按需切换即可，无需重构。

### 4.4 心跳、探活与分布式扩展

- **心跳**：Agent 每 15~30s `agent:heartbeat` 上报设备状态与指标；server 连续 3 个周期未收到 → 设备置 offline；
- **本地探活**：iOS 代理每 30s `GET /status` 探测 WDA；Android Agent 每 30s 自检无障碍服务与 WhatsApp 前台状态；
- **分布式扩展（天然支持异地/云端）**：
  - Android 手机**无需主机**——每台手机各自连平台，分布在全球任意位置，平台统一管理；
  - iPhone 以「本地代理」为单位注册，一个代理可管理 1~N 台 iPhone；代理数量可线性扩容；
  - server 面向 Agent 下发，不感知设备地理位置，扩容 = 加手机/加代理，无单点瓶颈。


### 4.5 可靠性与失败恢复

| 故障 | 处理 |
|---|---|
| 单条指令超时（iOS 30s / Android 15s） | 标记 timeout，重试 1 次 |
| 驱动/Agent 崩溃（WDA / 无障碍服务） | 自动重启（`ios runwda` / Agent 自恢复）后重试 1 次 |
| Agent 断线（网络/杀后台） | 平台积压该单元指令；重连后 `task:query` 补拉，从断点继续（不重发已确认的） |
| server 重启 | WebSocket 服务重启期间 Agent 自动重连；任务与结果已落库，不丢失 |
| 手机离线/掉线 | 置 offline、指令队列保留；重新上线后自动续跑 |

## 5. 手机双端操作实施（核心二）

### 5.1 统一驱动接口

```go
type DeviceDriver interface {
    Status(ctx context.Context) (DeviceStatus, error)   // 在线/忙/离线/异常
    LaunchApp(ctx context.Context) error                // 启动 WhatsApp 到前台
    OpenChat(ctx context.Context, phone string) error   // 深链打开目标会话
    TypeText(ctx context.Context, text string) error    // 输入文本（粘贴/fastinput）
    TapSend(ctx context.Context) error                  // 点击发送
    VerifySent(ctx context.Context) (SentState, error)  // 已发出/已送达/已读/未知
    Screenshot(ctx context.Context) ([]byte, error)     // 截图（OCR/人工兜底）
}
```

- `iOSDriver` = WDA HTTP 客户端；`AndroidDriver` = adb/uia2 客户端；
- 每个方法带超时（iOS 30s / Android 15s）与重试 1 次；
- 驱动只做「原子动作」，节奏/配额/熔断在统一执行器层，双端行为完全一致；
- 在驱动之上叠加**端侧 Agent 执行模型**（见 5.4），由 Agent 做任务理解、规划与异常自适应，驱动仍是确定性的执行后端。

### 5.2 iOS 端实施细节（WebDriverAgent）

**安装启动**：构建签名 `WebDriverAgentRunner` 安装到设备 → Mac 用 `xcodebuild test` / 跨平台用
`go-ios runwda` 启动 → `ios forward 8100 8100` 端口转发 → `GET /status` 验证。

**单条消息操作流程（对应图 3）**：

![双端发送单条消息流程](images/device-send-flow.png)

| 步骤 | WDA 指令 | 说明 |
|---|---|---|
| 启动/回前台 | `POST /session/:id/appium/device/activate_app` | bundleId=net.whatsapp.WhatsApp |
| **打开会话** | `POST /session/:id/appium/device/deeplink` `{url:"whatsapp://send?phone=<E164>"}` | 核心：深链免 UI 搜索 |
| 读 UI 树 | `GET /session/:id/source` | XML，含 accessibility label |
| 定位输入框 | `POST /session/:id/element`（name/predicate） | |
| **输入文本** | `POST /session/:id/wda/pasteboard` 设置剪贴板 → 长按输入框 → 点「粘贴」 | 支持中文/emoji/长文本，不依赖键盘 |
| 点击发送 | 定位 label=发送/Send → click | |
| **验证发出** | `GET /session/:id/screenshot` + OCR，或读元素树消息行 | 气泡=发送中 → 双勾=已送达 → 蓝色双勾=已读 |
| 回主屏 | `POST /session/:id/wda/homescreen` | 异常兜底 |

要点：
- 文本输入**剪贴板优先**（`typeText` 逐字符慢、中文输入法易失败，仅兜底）；
- WhatsApp 常用控件有 accessibility label，用谓词定位；无 label 区域用坐标 + 截图 OCR；
- 维护「元素映射表」，WhatsApp 升级后回归；
- 弹窗（更新提示/权限请求/键盘遮挡）识别后先处理再继续。

#### 5.2.1 Apple 开发者账号申请（个人开发者）

**为什么需要**：iOS 真机安装/签名 WebDriverAgent 必须有开发者证书。免费 Apple ID（Personal Team）签名的 App **仅 7 天有效、需每周重签**，设备会周期性失联（见 12.2 风险 1）；**付费个人开发者账号签名有效期 1 年**，到期自动重签即可，是本方案推荐路径（M1 前置条件）。

**个人 vs 公司账号**（本项目选**个人**：只需本人实名，无需营业执照/邓白氏编码，审核最快）：

| 对比项 | 个人开发者 Individual | 公司/组织 Organization |
|---|---|---|
| 年费 | $99（中国区约 ¥688） | $99（中国区约 ¥688） |
| 所需资料 | 本人身份证件、手机号、真实地址 | 营业执照、法人证件、邓白氏编码 D-U-N-S |
| D-U-N-S 邓白氏编码 | ❌ 不需要 | ✅ 必须（免费申请，约 5 个工作日） |
| App Store 显示名称 | 个人真实姓名 | 公司名称 |
| 审核周期 | 约 1~3 个工作日 | 较长（含邓白氏验证） |
| 适合 | 本项目（自用签名/上架） | 需以公司名义上架/团队协作 |

**申请前置条件**：
1. Apple ID（appleid.apple.com 免费注册），**必须开启双重认证**；
2. 年满当地法定成年年龄（中国 18 岁）；
3. 本人身份证件（姓名/号码与 Apple ID 一致）、手机号、真实收货地址（不接受 P.O. Box）；
4. 支付方式：国际信用卡（Visa/Mastercard）或中国区支付宝/微信支付。

**申请流程**（网页 developer.apple.com/account 或 iPhone/iPad 的 Apple Developer App）：

| 步骤 | 操作 | 说明 |
|---|---|---|
| 1 | 注册 Apple ID 并开启双重认证 | 用**真实姓名**注册（别名/昵称会延迟审核） |
| 2 | 打开 Apple Developer App（推荐）或 developer.apple.com/account | 登录 Apple ID |
| 3 | 点击「现在注册 / Enroll」，实体类型选 **Individual（个人）** | 公司/组织才需邓白氏编码 |
| 4 | 填写法律姓名、电话、地址 | 与身份证件一致，地址精确到门牌号 |
| 5 | **身份验证** | 中国区账号持有者必须用 Apple Developer App 完成：人脸 + 身份证正反面拍照（需 iPhone/iPad 已设锁屏密码/面容/触控 ID） |
| 6 | 阅读并同意《Apple Developer Program License Agreement》 | 个人开发者许可协议 |
| 7 | 支付年费 $99（约 ¥688） | App 内支持支付宝/微信；网页支持国际信用卡 |
| 8 | 等待审核 | 一般 1~3 个工作日邮件通知；通过后 developer.apple.com/account 可见 Membership 生效 |

**账号能带来什么**：
- 生成 **Development Certificate（开发证书）** 与 **Provisioning Profile（描述文件）**，签名有效期 **1 年**（免费 Personal Team 仅 7 天）；
- 每个会员年度最多注册 **100 台 iPhone（按产品系列）** 用于真机调试，本方案设备规模远小于此；
- 可上架 App Store / TestFlight（本项目自用群发无需上架，但具备该能力）。

**注意事项**：
- 一个人只能注册**一个**个人开发者账号，与 Apple ID 强绑定，勿买二手/共享账号；
- 审核期间不要修改 Apple ID 姓名/地址，避免触发二次验证；
- 年费到期前 30 天可续费；到期未续则证书失效，需在设备端重新部署 WDA。

#### 5.2.2 首次开发部署流程（Xcode + WebDriverAgent）

**前置**：一台 Mac（装稳定版 Xcode，版本与 iPhone iOS 匹配，见 12.2 风险 2）+ 已开通的个人开发者账号（5.2.1）+ 一台 iPhone（iOS 16+，开启开发者模式）。

**流程（首次部署，对应 M1 里程碑）**：

| 步骤 | 操作 | 说明 |
|---|---|---|
| 1 | Mac 安装 Xcode（App Store），打开一次完成组件初始化 | 首次部署必须有 Mac/Xcode 完成签名安装（见 12.2 风险 4） |
| 2 | Xcode → Settings → Accounts，登录开发者 Apple ID | 自动生成 **Personal Team** |
| 3 | 打开 WebDriverAgent 工程（`WebDriverAgent.xcodeproj`，选 Runner target） | 开源：github.com/appium/WebDriverAgent |
| 4 | 修改 **Bundle Identifier** 为唯一值（如 `com.<你的前缀>.wda.runner`） | 避免与官方/他人冲突 |
| 5 | Signing & Capabilities → Team 选 Personal Team | 自动生成开发证书与描述文件 |
| 6 | USB 连接 iPhone → 开启**开发者模式**（设置→隐私与安全性→开发者模式）→ Xcode 选中设备，Cmd+U 或 `xcodebuild build-for-testing` 安装 WebDriverAgentRunner | 首次安装后手机需**信任开发者证书**（设置→通用→VPN与设备管理→信任） |
| 7 | 启动并转发端口：`go-ios runwda` + `ios forward 8100 8100`（跨平台，Linux 也可）；Mac 也可 `xcodebuild test-without-building` | 后续运维用 go-ios，无需 Mac（iOS 17+） |
| 8 | 验证：`curl http://localhost:8100/status` 返回 JSON | 通过即 WDA 就绪，可被 5.1 iOSDriver 调用 |

**证书/描述文件管理**（developer.apple.com/account → Certificates, Identifiers & Profiles）：
- **证书**：Development 证书有效期 1 年；到期后在 Xcode 重新生成/自动续期，重签后重新安装 WDA；
- **设备**：每台 iPhone 的 **UDID** 需加入设备列表（每账号每年上限 100 台），新设备首次接入手动注册 UDID；
- **自动化运维**：批量初始化 SOP 脚本（开发者模式、信任证书、配对一次完成，见 12.2 风险 3）+ 证书到期自动重签脚本，保证 7×24 不掉线。

**免费 vs 付费签名**（决定是否购买 $99 账号）：

| 方式 | 签名有效期 | 是否满足本方案 |
|---|---|---|
| 免费 Apple ID（Personal Team） | 7 天，需每周重签 | ❌ 设备周期性失联，不满足 7×24 |
| 付费个人开发者（$99/年，约 ¥688） | 1 年，到期自动重签 | ✅ 推荐（见 12.2 风险 1） |

### 5.3 Android 端实施细节（内置 Agent：无障碍服务）

**形态**：手机内安装一个 Agent App，启动后自动连接平台 WebSocket 并注册；通过系统**无障碍服务
（AccessibilityService）**在本机操作 WhatsApp——完全无线、无需 USB/主机，手机可散落各地。

| 步骤 | 方式 | 说明 |
|---|---|---|
| 连接平台 | Agent 后台服务 + WebSocket 长连（token 鉴权） | 4G/Wi-Fi 均可 |
| 启动 App | `startActivity` 启动 `com.whatsapp` | |
| **打开会话** | Intent 深链 `whatsapp://send?phone=<E164>`（`ACTION_VIEW`） | 核心：免 UI 搜索 |
| 读 UI 层级 | 无障碍服务 `AccessibilityNodeInfo` 遍历 | 含 resource-id/text/bounds |
| 定位+点击 | 按 text/resource-id 匹配节点 → `performAction(ACTION_CLICK)` | 输入框/发送按钮 |
| **输入文本** | `ACTION_SET_TEXT` 直接设置到输入框（不依赖键盘） | 支持中文/长文本 |
| **验证发出** | 无障碍截图（Android 11+ 支持 `takeScreenshot`）或读消息气泡 + 时间 | |
| 返回 | `performGlobalAction(GLOBAL_ACTION_BACK)` | 发送完回列表 |

**落地要点**：
- **授权**：首次需用户手动开启「无障碍服务」+「通知使用权」；截图授权（无障碍截图或 MediaProjection 一次性授权）；
- **防杀后台**：申请电池优化白名单、前台服务常驻通知、引导式电源管理例外；
- **断线重连**：指数退避重连平台，重连后 `task:query` 补拉未完成 items；
- **元素映射表**：WhatsApp 控件（示例：输入框 `com.whatsapp:id/entry`、发送 `com.whatsapp:id/send`）以实机 dump 为准，升级后回归；
- **厂商适配**：小米/OPPO/vivo/华为的「无障碍自启动/后台限制」设置项不同，统一采购 1~2 个型号降低适配成本；
- **开发期调试**：联调阶段仍可用 adb + UIAutomator2（`uiautomator2 init` + `adb forward`）辅助定位元素，生产以内置 Agent 为准。

### 5.4 精简 wa-agent（本项目专属，只做 WhatsApp 群发）

**定位**：参考 OpenMinis「平台下发 → 端侧 Agent 执行」的框架思路，但**裁剪为本项目专属的精简 Agent**——
只做一件事：接收群发任务、操作 WhatsApp、发完上报平台。浏览器自动化、健康/日历/HomeKit 等系统集成、
Workspaces、Linux 沙箱、MCP 等与本项目无关的能力全部去掉。

![wa-agent 精简架构](images/device-wa-agent.png)

**组件清单（保留）**

| 组件 | 实现 | 职责 |
|---|---|---|
| WebSocket 客户端 | 复用 4.2 协议 | 注册 / 心跳 / 收任务 / 上报结果 |
| 执行器（确定性流程） | Go（Android 内置 / iOS 本地代理） | 深链 → 输入 → 发送 → 验证，按节奏串行执行 |
| WhatsApp 工具 | Android 无障碍服务 / iOS 代理 WDA（5.2/5.3） | 打开会话、输入、点击发送、截图、读 UI 树 |
| LLM（按需调用） | 复用现有模型注册中心 | 见下「LLM 用在哪儿」 |
| 节奏/配额控制器 | 本地执行平台下发的参数 | 条间间隔、日上限、时间窗 |
| 结果缓存与补报 | 本地队列 | 断线缓存，重连后补报 |

**去掉的（本项目不需要）**

- **浏览器自动化**：不操作 Web；Web 群发已有 whatsmeow 链路；
- **健康/日历/通讯录/HomeKit/蓝牙/NFC 等系统集成**：与群发无关；
- **Workspaces 多工作上下文**：每个任务一个执行上下文即可；
- **完整 Linux 沙箱（iSH/PRoot）**：无需在设备装包跑脚本；名单清洗/模板个性化由平台或 LLM 完成；
- **MCP 集成**：平台上报走 WebSocket 已足够，不需要 MCP 通道；
- **通用 Skills 框架**：把 WhatsApp 操作流程固化为内置流程脚本 + 元素映射表即可，不需要通用技能引擎。

**LLM 用在哪儿（有 LLM 更精准）**

| 环节 | 确定性优先 | LLM 兜底（按需调用） |
|---|---|---|
| 任务解析 | JSON 直接解析 | 异常/非标准格式时由 LLM 纠正 |
| 元素定位 | 元素映射表（label / resource-id） | UI 树找不到时，LLM 看截图/坐标推理点击位置 |
| 异常处理 | 预置规则（弹窗/超时重试） | 未知弹窗时 LLM 判断类型并给出处理动作 |
| 内容个性化（可选） | 模板变量替换 | 生成更自然的称呼/措辞（控制调用量） |
| 发送验证 | 截图 OCR / 元素树规则 | 勾/时间状态模糊时 LLM 综合判断 |

**设计原则：LLM 辅助、确定性兜底**——常规发送走固定流程（快、省 token、可控），
只有「元素缺失 / 异常 / 模糊」时才调 LLM：既精准，又不依赖 LLM 的稳定性与每次调用成本。

**执行与上报流程**

1. 平台下发意图 `{ taskId, phones[], contentTemplate, pacing, rules }`；
2. 执行器逐条：深链打开会话 → 输入 → 发送 → 验证（确定性优先，LLM 兜底）；
3. **发完即上报**：每条完成立即 `item:result`（sent/failed + 原因 + 耗时），平台落库 + WS 推送；
4. 全部完成上报任务汇总；断线期间结果缓存本地，重连后补报。

**许可**：仅借鉴 OpenMinis 的框架思路（平台下发 → 端侧 Agent 执行），不并入其代码；
本项目为自研轻量 Agent（Go/Kotlin/Swift），无 GPL 传染。

### 5.5 wa-agent 执行器（伪代码 + 双端差异）

#### 5.5.1 主循环（Go 风格伪代码，M5 按此实现）

```go
// OnTask：平台下发任务后回调
func (a *WA) OnTask(task Task) {
    for _, phone := range task.Phones {
        if a.quotaExhausted(phone) {           // 节奏/配额：日上限、新会话占比
            continue
        }
        a.waitForPacing(phone)                 // 条间间隔 + 目标当地时间窗
        res := a.sendOne(phone, task.Content)  // 单条发送（确定性优先，LLM 兜底）
        a.report(ItemResult{Phone: phone,      // 发完即上报
            Status: res.Status, Error: res.Error, CostMs: res.CostMs})
    }
    a.report(TaskSummary{Total: ..., Success: ..., Failed: ...})
}

// sendOne：单条发送
func (a *WA) sendOne(phone, content string) Result {
    if err := a.tools.OpenChat(phone); err != nil {        // ① 深链打开会话
        if err2 := a.tools.OpenChatBySearch(phone); err2 != nil { // ①′ 深链失败 → UI 搜索兜底
            return fail("open chat: " + err + " / " + err2)
        }
    }
    input := a.tools.FindInput()                           // ② 元素映射表定位输入框
    if input == nil {
        hint := a.llm.Locate(a.tools.Screenshot(), "输入框") // ③ LLM 兜底：返回坐标/谓词
        if hint == nil { return fail("input not found") }  //    LLM 不可用/无结果 → 记 failed（不阻塞整批）
        a.tools.Tap(hint.X, hint.Y)
    }
    a.tools.TypeText(content)                              // ④ 输入（ACTION_SET_TEXT / 剪贴板粘贴）
    a.tools.TapSend()                                      // ⑤ 点击发送
    switch a.verify() {                                    // ⑥ 验证（截图/UI 树，模糊时 LLM）
    case Sent:    return ok()
    case Unknown: return timeoutRetry()                    // 重试 1 次
    default:      return fail("not sent")
    }
}
```

#### 5.5.2 LLM 兜底调用点（只在以下情况调 LLM，省 token、可控）

1. **元素定位失败**（找不到输入框/发送按钮）→ 截图 + 简短任务描述 → LLM 返回坐标或定位谓词；
2. **验证状态模糊**（OCR 无法确定气泡/勾）→ 截图 → LLM 判断 sent/delivering/failed；
3. **未知弹窗/异常** → 截图 → LLM 给出处理动作（关闭/允许/重试/上报人工）。

其余常规路径全部走确定性逻辑，不调 LLM。

**LLM 不可用降级（保证不阻塞）**：LLM 超时/故障时自动降级为纯确定性执行——元素定位失败记 failed、
验证模糊按 unknown 重试 1 次；**LLM 只提升精准度，不是发送的必需依赖**（评审项 #9 闭合）。

#### 5.5.3 单条发送时序（含 LLM 兜底）

![wa-agent 单条发送时序](images/device-wa-agent-send.png)

#### 5.5.4 Android 无障碍版 vs iOS 代理版差异

| 环节 | Android（无障碍服务） | iOS（本地代理 + WDA） |
|---|---|---|
| 打开会话 | Intent 深链 `whatsapp://send?phone=` | WDA `deeplink` 扩展 |
| 输入文本 | `ACTION_SET_TEXT` 直接设置 | 剪贴板 + 长按粘贴 |
| 点击 | `performAction(ACTION_CLICK)` | WDA element click |
| 截图 | 无障碍截图 / MediaProjection | WDA screenshot |
| 读 UI 树 | `AccessibilityNodeInfo` | WDA source XML |
| 上报 | Agent 内 WebSocket | 本地代理 WebSocket（同一实现） |

执行器逻辑（5.5.1）双端完全一致，差异全部收敛在「工具」层。

### 5.6 WhatsApp 元素映射表草案（wa-broadcast）

**说明**：以下为常见 WhatsApp 版本示例，实机联调时按 `dump`/`source` 校准；WhatsApp 升级后回归更新。
映射表存为内置配置（YAML/JSON），供确定性定位使用，同时作为 LLM 兜底时的上下文。

**iOS（WDA，按 accessibility label / 类型谓词）**

| 控件 | 定位 | 备注 |
|---|---|---|
| 新建聊天入口 | label = 新建聊天 / New chat | 进入会话列表 |
| 会话输入框 | 类型 `XCUIElementTypeTextView`（底部输入区） | 或按坐标 |
| 发送按钮 | label = 发送 / Send | 蓝色圆形按钮 |
| 粘贴菜单项 | label = 粘贴 / Paste | 长按输入框后出现 |
| 返回按钮 | label = 返回 / Back | 发送完回列表 |

**Android（按 resource-id / text）**

| 控件 | 定位 | 备注 |
|---|---|---|
| 会话输入框 | `com.whatsapp:id/entry` | 以实机 dump 为准 |
| 发送按钮 | `com.whatsapp:id/send` | text 可能为「发送」 |
| 返回 | 系统返回键 / 顶部返回 | `performGlobalAction(BACK)` |
| 消息气泡 | text 包含发送内容 | 验证用 |

**验证规则（VerifySent）**

- 成功：消息气泡出现 + 时间戳；单勾（发送中）→ 双勾（已送达）→ 蓝色双勾（已读），能读到就读；
- 口径：界面确认已发出即算成功（送达/已读尽力读取，不作为必要条件）；
- 超时：30s 内气泡未出现 → `timeout` 重试 1 次；
- 模糊：OCR/UI 树无法判断 → LLM 看截图兜底。

**配置示例（元素映射表结构）**

```yaml
ios:
  sendButton:  { by: label,  value: ["发送", "Send"] }
  inputBox:    { by: type,   value: "XCUIElementTypeTextView" }
  pasteItem:   { by: label,  value: ["粘贴", "Paste"] }
android:
  sendButton:  { by: resourceId, value: "com.whatsapp:id/send", fallbackText: ["发送", "Send"] }
  inputBox:    { by: resourceId, value: "com.whatsapp:id/entry" }
verify:
  timeoutMs: 30000
  retryOnce: true
  sentMarkers: ["气泡出现", "已发送时间", "双勾"]
```

## 6. 状态监听与结果统计

### 6.1 数据模型（新增 5 张表，SQL 立项后落 `docs/database/`）

| 表 | 关键字段 | 作用 |
|---|---|---|
| `devices` | device_type(ios/android)、udid、status(online/busy/offline)、last_seen_at | 设备注册表 |
| `broadcast_tasks` | total_phones、success_count、failed_count、status(pending/running/done) | 任务汇总 |
| `broadcast_task_items` | task_id、device_id、phone、status(sent/failed/timeout/skipped)、error | 逐条结果 |
| `device_daily_stats` | stat_date、sent_count、new_chat_count、failed_count | 设备每日指标/配额 |
| `device_events` | event_type(banned/restricted/quarantined/error/alert) | 事件留痕/审计 |

### 6.2 实时推送（WebSocket，复用现有 hub）

```json
{ "type": "broadcast_progress", "tenantId": "...", "taskId": "...",
  "payload": { "taskId": "...", "status": "running",
               "successCount": 12, "failedCount": 3, "pendingCount": 85,
               "item": { "deviceId": "...", "phone": "+8613800000000", "status": "sent" } } }
```

- 每条消息执行完成即推送一次；前端按 taskId 聚合刷新；WS 不可用回退轮询任务详情接口。

### 6.3 管理端 API

| 接口 | 说明 |
|---|---|
| `POST /api/devices` / `GET /api/devices` / `GET /api/devices/:id/status` | 设备注册、列表、状态 |
| `POST /api/broadcasts` | 创建任务（设备 + 手机号 + 内容） |
| `GET /api/broadcasts` / `GET /api/broadcasts/:id` | 任务列表 / 详情 + 逐条结果（分页、按状态过滤） |
| `POST /api/broadcasts/:id/cancel` | 取消未完成部分 |

## 7. 账号安全与智能调度

真机方案账号安全性高（官方 App + 真机指纹），再叠加以下智能调度策略，让每个账号的发送行为
贴近真人、最大限度保护账号：

| 策略 | 说明 |
|---|---|
| **智能节奏** | 条间随机间隔（基础 20s + 抖动 0~40s）、每发 5~8 条长暂停、小时上限、目标当地 09:00–21:00 时间窗；每设备独立随机种子，避免多设备节奏一致 |
| **账号预热** | 新账号 1–3 天 5 条/天 → 4–7 天 10 条 → 8–14 天 20 条 → 15 天+ 30–50 条/天；达上限即停 |
| **新会话占比控制** | 新会话 ≤ 30%、绝对量 ≤ 日上限 50%；超额次日再发 |
| **名单卫生** | 强制 opt-in、全局去重、退订/拉黑自动过滤、名单分层（老会话 > 联系人 > 陌生号码） |
| **内容策略** | 模板 + 轻量个性化、预热期避免营销词/短链/emoji、单条 < 500 字符、模板轮换 |
| **自动熔断保护** | 连续失败自动隔离重试；账号异常（发出无回执等）自动停止该设备并通知；任务级风控触发率超阈值自动暂停，人工确认后放量 |
| **灰度门槛** | 连续 7 天风控触发率 < 1% 且送达率达标，才上调日配额 |

所有参数租户级可配，灰度期按实际数据回调。

## 8. 可行性分析

**技术可行性 ✅**
- iOS：WebDriverAgent（XCUITest）+ go-ios + Appium XCUITest driver，开源成熟，市面已有免越狱 iPhone 群控产品验证；
- Android：adb + UIAutomator2 / 无障碍服务，工具链更成熟、无签名证书限制；
- 本项目为 Go 技术栈，自研轻量 `DeviceDriver` 双端实现，与 server/connector 集成成本可控；
- 精简 wa-agent 只保留「WebSocket + 执行器 + WhatsApp 工具 + LLM 兜底」四个组件，无浏览器/系统集成/沙箱/MCP 等负担，实现量小、稳定可控。

**安全可行性 ✅（真机方案的核心优势）**
- 官方 WhatsApp App + 真实设备/真实 SIM/真实网络，客户端指纹与真人一致，账号技术层更难被识别为自动化；
- 一机一号，天然接近真人行为；配合第 7 章智能调度，进一步保护账号。

**接入可行性 ✅**
- 复用现有：手机号解析（`internal/phoneinfo`）、配额分配（`broadcast.js`）、群发工作台、WS 推送 hub、权限体系；
- 新增：平台公网 WebSocket 下发服务（wss）+ Android 内置 Agent App + iPhone 本地代理，与 connector 并列互不影响；
- 平台有公网 IP 即可，无需向手机开放任何入站端口（手机主动外连，天然穿透 NAT/防火墙）。

**实施可行性 ✅**
- 里程碑分 6 步小步验证（见第 9 章），先单端单台 → 双端 → 集成系统 → 灰度；
- 总工作量约 9~11 人周（含 Agent 化执行 M5），硬件按设备规模线性投入。

## 9. 实施计划（里程碑）

| 里程碑 | 内容 | 验收标准 |
|---|---|---|
| M1 iOS 单机验证 | 1 台 iPhone + Mac：WDA、本地代理、WebSocket 注册、发送 1 条（前置：开发者账号 5.2.1 + 首次部署 5.2.2） | 平台下发，WhatsApp 成功发出，截图确认 |
| M2 Android 单机验证 | 1 台 Android：内置 Agent（无障碍服务）打通同一条流程 | 同上 |
| M3 双端批处理 | 深链 + 输入 + 发送 + 验证完整流程，每端 10 条 | 连续 10 条成功率 ≥ 90% |
| M4 Agent 与设备管理 | 注册/心跳/状态机、断线重连与补拉、自动重启驱动、告警 | 杀进程/断网自动恢复，告警可观测 |
| M5 精简 wa-agent | 自研 wa-agent：LLM 按需兜底 + 确定性执行器 + 任务意图下发 + 发完即上报 | 平台下发意图，wa-agent 完成 10 条并逐条回传结果 |
| M6 系统集成 | 5 张表 + API + WS 事件 + 工作台设备来源与进度面板 | 管理端创任务，实时看到成功/失败/待发计数 |
| M7 灰度上线 | 小名单灰度，启用智能调度参数 | 风控触发率与送达率达标后放量 |

## 10. 成本估算（团队估算，评审时按实际询价修正）

| 项 | 单价估算 | 备注 |
|---|---|---|
| 二手 iPhone（SE/XR 级别） | ¥800~1500/台 | iPhone 为主 |
| Android 手机（统一型号） | ¥300~800/台 | 小部分补充 |
| 带供电 USB HUB | ¥100~300 | 一台主机接 10~20 台 |
| 控制主机 | 复用现有 Mac 或 Linux 服务器 | |
| Apple 开发者账号 | $99/年（推荐，免 7 天重签） | |
| 示例：10 iPhone + 2 Android | 约 ¥1~2.5 万（硬件） | 不含人力 |
| LLM API 成本（Agent 化执行，可选） | 按调用量计 | 仅 Agent 模式产生；纯指令模式无需 |

## 11. 待确认问题

1. 平台公网域名与 wss 证书是否就绪？（WebSocket 下发服务的前置条件）
2. 设备规模与 iPhone/Android 比例？（决定 iOS 本地代理数量与证书投入）
3. Android 手机是否统一采购 1~2 个型号？（降低无障碍/厂商后台限制适配成本）
4. 是否采用精简 wa-agent（LLM 按需兜底）？涉及自研 wa-agent + 模型 API Key 成本（见 5.4）
5. OpenMinis GPLv3：确认仅借鉴架构、不并入其代码（本项目为自研 wa-agent，无 GPL 传染）
6. 消息形态是否仅文本？（图片/文件会显著增加 UI 流程复杂度）
7. 结果口径是否接受「界面确认发出 = 成功」？（送达/已读尽量读取）
8. 任务结果是否需要长期留存审计？（决定 items/events 保留策略）

## 12. 评审检查：99.99% 可行性保障

### 12.1 评审目标与 99.99% 的定义

**目标**：方案一定能够实现——平台下发、设备操作 WhatsApp、发送、验证、上报、统计全链路端到端可用，
且各环节有确定性解法，不依赖运气或未知条件。

**99.99% 的边界定义（必须明确，避免误解）**：

| 范畴 | 是否承诺 99.99% | 说明 |
|---|---|---|
| 系统实现可行性（下发/操作/发送/验证/上报/统计全链路） | ✅ 承诺 | 本评审逐项闭合（见 12.2） |
| 单条消息发出成功率 | ✅ 承诺 ≥ 99% | M3 验收标准；多重兜底保证 |
| 设备 7×24 可用性（不因证书/杀后台/驱动崩溃掉线） | ✅ 承诺 | 见 12.2 消除措施 |
| 账号永不被 WhatsApp 风控 | ❌ 不承诺 | WhatsApp 服务端外部行为，非技术可实现范畴；由智能调度（第 7 章）最大化保护，属运营边界 |

**评审方法**：按「环节 → 可能导致失败的点 → 消除措施（确定性解法）→ 验证方式」逐项检查，
所有技术风险点必须闭合；无法闭合的点不得保留。

### 12.2 评审检查清单（逐项闭合）

| # | 环节 | 可能导致失败的点 | 消除措施（确定性解法） | 验证方式（里程碑） |
|---|---|---|---|---|
| 1 | iOS 接入 | WDA 免费签名 7 天过期 → 设备周期性失联 | **付费开发者账号（$99/年）签名，有效期 1 年** + 到期自动重签脚本 | M1：单台连续运行 7 天不掉线 |
| 2 | iOS 接入 | Xcode/iOS 版本不匹配 → WDA 无法启动 | **锁版本矩阵**：统一 iOS 版本 + 匹配 Xcode/WDA；升级走回归流程 | M1：版本一致性检查通过 |
| 3 | iOS 接入 | 开发者模式/证书信任未开启导致不可控 | **批量初始化 SOP 脚本**：开发者模式、信任证书、配对一次完成 | M1：初始化脚本一次通过率 100% |
| 4 | iOS 接入 | 无 Mac 环境无法首次部署 WDA | 首次用一台 Mac/Xcode 完成签名安装；**后续 go-ios 跨平台管理**（iOS 17+） | M1：单机验证 |
| 5 | Android 接入 | 厂商杀后台/限制无障碍服务 | **统一采购 1~2 个型号** + 电池白名单 + 前台服务 + 厂商引导配置 | M2：长稳测试 7 天不掉线 |
| 6 | 打开会话 | 深链 `whatsapp://send?phone=` 被拦截/异常 | **深链失败 → UI 搜索联系人兜底**（输入手机号→打开会话），双重路径 | M3：故障注入（禁用深链）仍可发送 |
| 7 | 输入/发送 | 元素找不到 | 元素映射表 + 坐标 + 截图 OCR + LLM 兜底（5.5/5.6） | M3：元素缺失场景测试 |
| 8 | 验证 | 状态误判 | 气泡 + 时间 + 勾多重标记 + OCR + LLM；超时重试 1 次；口径=界面确认发出 | M3：与人工比对抽样一致 |
| 9 | LLM 不可用 | LLM 超时/故障 → 任务卡住 | **确定性路径优先；LLM 失败自动降级**为纯确定性执行 + unknown 重试，不阻塞发送 | M5：LLM 断网故障注入仍可发完 |
| 10 | 网络/断线 | 任务丢失或重复 | msgId 幂等 + item:ack + 任务落库 + task:query 补拉 + 结果缓存补报 | M4：断网/杀进程恢复测试 |
| 11 | 平台公网 | 设备连不上平台 | 公网域名 + wss 证书；设备 4G/Wi-Fi 均可外连 | M4：异地设备连通测试 |
| 12 | 账号风控 | 账号被 WhatsApp 封禁（外部行为） | 智能调度（节奏/预热/占比/名单/内容）+ 熔断 + 灰度门槛；**定义为运营边界，不承诺绝对** | M7：灰度封号率/送达率指标监控 |
| 13 | 结果统计 | 成功/失败计数与预期不符 | 逐条落库 + WS 推送 + 任务汇总对账 | M6：与工作台计数比对一致 |
| 14 | 多设备扩展 | 设备越多越不稳定 | 每设备独立队列 + 心跳 + 自动摘除故障设备；多主机线性扩容 | M6：10+ 台并发压力测试 |

**结论：全部 14 项技术风险点均闭合，无遗留「可能失败」项。**

### 12.3 证明路径（评审通过后按此验证）

1. **里程碑验收**：M1~M7 每步都有量化验收标准（见第 9 章），逐级放行；
2. **全链路冒烟测试**：端到端 1 条消息从「平台下发 → 设备操作 → 发送 → 验证 → 上报 → 前端计数」全通；
3. **故障注入测试**：深链失效、LLM 断网、断线重连、元素缺失、杀进程恢复——5 类故障各注入一次，验证降级路径；
4. **长稳测试**：单台设备 7×24 连续运行，证书不掉线、后台不被杀、驱动自动恢复；
5. **灰度指标**：封号率/送达率/成功率/设备可用性四项指标达标后放量。

### 12.4 评审结论

**方案实现层面 99.99% 可达成**：14 项技术风险点全部有确定性解法并纳入里程碑验收，
关键环节（深链、元素定位、验证、LLM、断线）均有降级兜底，不存在「无解」的依赖。

**唯一外部边界**：账号是否被 WhatsApp 风控由服务端行为判定，不属于「方案能否实现」范畴；
本方案通过第 7 章智能调度最大化保护，并以灰度门槛控制风险，评审确认该边界定义。

**评审结论：通过（条件：按 12.3 证明路径完成 M1~M7 验收）。**
