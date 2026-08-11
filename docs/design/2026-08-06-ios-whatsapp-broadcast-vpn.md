# iOS WhatsApp WDA 自动化群发详细设计（EasyTier 内嵌、公网 Wi-Fi/蜂窝组网）

> **供 Claude/Codex 实施：**严格按本文里程碑和复选框顺序开发。M0 未全部通过时不得实现 M1 之后的生产功能，不得把条件可行写成已验证可行。

- 日期：2026-08-06
- 状态：详细设计完成，等待 M0 真机门禁验证
- 范围：仅 iOS；不设计、不实现其他移动端
- 关联文档：`docs/design/2026-08-04-iphone-whatsapp-broadcast-feasibility.md`
- 目标：自研 iOS App 内嵌 EasyTier Core，通过可访问公网的 Wi-Fi 或 4G/5G 与美国服务器双向组网；首次 USB 激活 WDA 后，连续运行期不依赖 USB 或同一局域网，由美国服务器通过 iPhone EasyTier 虚拟 IP 的 `8100` 端口全自动操作官方 WhatsApp App 发送消息

---

## 1. 最终结论与不可变约束

### 1.1 唯一目标架构

本项目只实施以下架构，不再保留“外装 WireGuard App”“WireGuard Portal”“现场主机代理”或“预填后由用户点发送”等并行方案：

1. 自研 iOS App 内包含主 App 和 `PacketTunnelProvider` Network Extension。
2. `PacketTunnelProvider` 静态链接 EasyTier v2.6.4 Core；内部分发轨通过 FFI 交付 TUN fd，App Store 轨通过公共 `NEPacketTunnelFlow` 双向 packet bridge 交付 IP packet，两轨不混编。
3. iPhone 可用 Wi-Fi、4G/5G 或二者切换主动连接美国服务器上的 EasyTier 实例；只要求底层网络可访问公网，不要求设备和服务器位于同一局域网，也不安装第二个 VPN App。
4. iPhone 与 `us.hsddns.com` 服务端加入同一 EasyTier 共享网络（`wa-ios`，网段 `10.168.0.0/16`）；服务端固定公网监听端口 `11010/11011`，设备虚拟 IP 由服务端分配并随注册下发；WDA `8100` 隔离由 EasyTier ACL 保证（5.1）。
5. 美国服务器运行 `ios-controller` 和 EasyTier Core；`ios-controller` 通过 `http://<iphone-vpn-ip>:8100` 直接调用已运行的 WDA。
6. `ios-controller` 自动打开 WhatsApp 会话、校验收件人、输入正文、点击发送、验证新消息气泡并上报结果。
7. 点击发送不需要前台用户确认。iPhone 必须处于已解锁、屏幕常亮、WhatsApp 可用的受管状态。
8. iOS App 可通过 HTTPS/WSS 注册和上报，但群发任务不依赖普通 App 的后台长连接；任务权威执行者是美国服务器的 `ios-controller`。

### 1.2 USB 结论

“激活以后不需要 USB”只对一个连续运行周期成立，不代表永久免 USB：

| 场景 | USB/现场操作 | 系统行为 |
|---|---:|---|
| 首次配对、开发者模式、签名安装 App/WDA、首次启动 WDA | 必须 | 使用 Mac + Xcode + USB 完成 |
| 已激活且 WDA/XCTest 仍存活，iPhone 未重启 | 不需要 | 通过 Wi-Fi 或 4G/5G 承载 EasyTier 虚拟网远程控制 |
| EasyTier 隧道断线后恢复 | 通常不需要 | Network Extension 按需重连，虚拟 IP 不变 |
| WDA/XCTest 被系统终止、签名失效、iPhone 重启、开发者模式关闭 | 需要 USB 或现场重新启动 | 设备进入 `recovery_required`，不得假装在线 |

因此必须先通过 M0-B1、M0-B2 和 M0-C：分别证明蜂窝-only、Wi-Fi-only、Wi-Fi/蜂窝切换以及脱离 USB/Mac 24 小时运行。关闭 Wi-Fi 只是蜂窝专项测试条件，不是产品运行条件。任一门禁失败时，后续平台开发立即停止，不能把未验证的承载方式标为支持。

### 1.3 发送确认结论

WDA 是 XCTest UI 自动化服务，能够直接执行点击。系统不会使用 `UIApplication.open` 只做预填后等待用户确认，而是执行完整闭环：

```text
创建/复用 WDA session
  -> 打开 whatsapp://send 深链
  -> 校验目标会话与输入框
  -> 校验/写入消息正文
  -> 在数据库提交 send_click_committed 边界
  -> WDA click 发送按钮（只调用一次）
  -> 校验输入框清空且出现本次新增的出站气泡
  -> sent / unknown
```

`sent` 仅表示 WDA 看到了本次新增的出站消息气泡，不等于 WhatsApp 服务端送达、对方已读或账号不会受风控。

### 1.4 App Store 与 WDA 激活结论

“自研 App 上架”和“激活 WDA”是两个独立问题，必须按以下边界实现：

| 能力 | App Store 版主 App 能否完成 | 实施方式 |
|---|---:|---|
| enrollment、Keychain、VPN profile、EasyTier 组网、状态上报 | 条件可行 | Network Extension 全部使用 Apple 公共 API，并取得所需 entitlement/审核许可后交付 |
| 安装、签名或首次启动 WDA/XCTest Runner | 不能 | 由受控 Mac、Xcode、付费开发者签名和 USB 配对完成 |
| WDA 存活期间经虚拟 IP `:8100` 自动发送 | 能 | App 只承载 EasyTier 数据面，发送由美国 `ios-controller` 调 WDA |
| iPhone 重启、WDA 被杀或签名失效后由 App 自动恢复 WDA | 不能 | 转 `recovery_required`，重新执行第 8.3 节恢复 SOP |

普通 App 没有安装其他 App、签发开发者测试包或启动 XCTest test runner 的系统权限。即使主 App 已从 App Store 安装，页面上的“激活 WDA”按钮也不能绕过该限制；v1 不实现这个误导性按钮。App Store 更新主 App 也不会激活或续签独立的 WDA Runner。

当前 v1 的 EasyTier TUN 接入使用未公开 KVC fd，只用于 Development、Ad Hoc 或企业内部分发。若要提交 App Store，必须先完成第 4.1 节公共 `NEPacketTunnelFlow` 桥接门禁；这只解决主 App/Network Extension 的送审问题，不改变 WDA 仍需 USB/Xcode 激活的结论。

### 1.5 明确不做

- 不实现 Android。
- 不安装或调用 WireGuard iOS App，不使用 EasyTier WireGuard Portal。
- 不让 iOS 普通 App 使用 Accessibility 自动化其他 App；iOS 端自动化只走 WDA/XCTest。
- 不让浏览器、用户输入或普通 API 自由指定 WDA URL、IP、端口或协议。
- 不将现有 `POST /api/accounts/:id/send-many` 改造成 WDA 群发；两种传输链路独立。
- 不承诺 iPhone 重启后远程自启 WDA。
- 不声称 v1 私有 KVC TUN 实现可直接提交 App Store。
- 不在上架 App 内实现虚假的“安装/激活 WDA”能力。
- 不自动重发 `unknown` 项，防止重复消息。

## 2. 现状基线与版本锁定

### 2.1 本仓库已核验基线

| 项目 | 当前事实 | 本设计要求 |
|---|---|---|
| 后端 | Go 1.26、Gin 1.12、pgx/v5、默认 `:8790` | 复用现有 Gin、错误体、session/CSRF/RBAC 模式 |
| 前端 | Vue 3.5、Element Plus、Vite 8、Vitest、pnpm 11 | 新增独立 iOS 设备与群发视图 |
| 数据库 | PostgreSQL；启动期内联 DDL；ID 为 `genID()` 生成的 24 位十六进制 `TEXT` | 新表 ID 均为 `TEXT`，禁止改用 UUID |
| 浏览器 WS | `GET /api/ws`，session 鉴权，只做服务端到浏览器推送 | 仅扩展事件类型，不复用为设备 Agent WS |
| 内部事件 | `POST /api/internal/events`，`INTERNAL_API_TOKEN` | iOS 控制器使用独立 `IOS_CONTROLLER_TOKEN` |
| 当前群发 | `POST /api/accounts/:id/send-many` 同步、不落任务表 | iOS 群发新增持久化任务、逐项租约和审计 |
| RBAC | DB 菜单树、租户 ceiling、角色授权 | 新增确定性菜单 ID 和权限码，并给存量租户显式补齐 |

### 2.2 外部依赖固定版本

| 依赖 | 固定版本/提交 | 选择依据 |
|---|---|---|
| EasyTier | `v2.6.4` / `8428a89d2dabc94c97d370ec607c6ca142473626` | 已核验 FFI、iOS mobile cfg、raw fd TUN 支持 |
| WebDriverAgent | `v16.1.5` / `c93561a4c48c220ba630a22771ca87dd479d6663` | 已核验 `/status`、`/session`、`/url`、element、source、screenshot 路由 |
| Rust | EasyTier 仓库 `rust-toolchain.toml` 的 `1.95` | 不使用本机默认 Rust 替代 |
| iOS | 最低 iOS 16.4 | 固定 v1 真机矩阵，减少 WDA/深链差异 |
| Xcode | M0 记录中的固定版本 | 必须与测试设备 iOS 和 WDA v16.1.5 实测兼容 |

升级任一版本必须重新执行 M0-A、M0-B1、M0-B2、M0-C、M0-D；若交付 App Store 轨，还必须重新执行 M0-E，不允许只通过编译就升级生产。

### 2.3 已核验的 EasyTier 源码事实

EasyTier v2.6.4 已有移动端核心，但没有现成 iOS App 封装：

- `easytier-contrib/easytier-ffi/src/lib.rs` 导出 `parse_config`、`run_network_instance`、`set_tun_fd`、`retain_network_instance`、`collect_network_infos`、`get_error_msg`、`free_string`。
- `easytier/build.rs` 把 `target_os = "ios"` 归入 `mobile`。
- `easytier/src/instance/virtual_nic.rs` 的 `run_for_mobile`/`create_dev_for_mobile` 接受 raw TUN fd，并针对 iOS 处理 4 字节 packet information header。
- FFI 当前 crate 类型只有 `cdylib`，没有 iOS XCFramework、Swift Bridge、C Header 或 Network Extension target。
- 上游移动 CI 当前只构建 Android，不能把“有 mobile cfg”误认为“官方已交付 iOS SDK”。

## 3. 架构、信任边界与数据流

```text
管理浏览器
   | HTTPS + session/CSRF/RBAC
   v
server :8790 ---------------------- PostgreSQL
   |  ^                              devices/tasks/items/audit
   |  | HTTPS(loopback 优先) + IOS_CONTROLLER_TOKEN
   v  |
ios-controller（美国服务器，systemd）
   |  |-- 管理单个 EasyTier Core 进程（单进程多实例，5000 设备）
   |  |-- 固定目标 http://10.168.x.y:8100
   |  `-- WDA session / WhatsApp UI 自动化
   |
   | EasyTier 加密隧道（公网 UDP，TCP 回退）
   v
iPhone（公网 Wi-Fi 或 4G/5G，可切换）
   |-- 自研 App：注册、配置、状态展示、前台 HTTPS/WSS 上报
   |-- PacketTunnelProvider：EasyTier FFI + TUN fd
   |-- WDA :8100：已通过 USB/Xcode 激活并保持运行
   `-- 官方 WhatsApp App
```

### 3.1 权威来源

| 信息 | 权威来源 | 非权威来源 |
|---|---|---|
| 任务/逐项状态 | PostgreSQL | 浏览器内存、WSS 消息 |
| WDA 在线 | 美国控制器主动 `GET /status` | iOS 普通 App 是否在线 |
| VPN 可用 | WDA TCP 探活 + EasyTier 运行信息 | 单独的 App 心跳 |
| 发送成功 | 点击后的新增出站气泡验证 | 深链成功、输入框有文字、click 返回 200 |
| iOS App 状态 | 最近 HTTPS/WSS 上报 | 不能替代 WDA 状态 |

### 3.2 组件职责

| 组件 | 只负责 | 不负责 |
|---|---|---|
| iOS 主 App | 入网、Keychain、VPN profile、状态展示、前台状态上报 | 自动点击 WhatsApp、后台任务调度 |
| Packet Tunnel | EasyTier 生命周期、TUN、隧道统计 | 任务、消息正文、WDA 调用 |
| EasyTier Core | 虚拟网数据面 | 设备鉴权 API、任务幂等 |
| WDA | XCTest UI 原子操作 | 业务重试、任务状态、合规策略 |
| `ios-controller` | WDA 探活、逐设备串行执行、结果回传 | 租户 RBAC、浏览器 session |
| `server` | 注册、RBAC、任务、租约、审计、浏览器事件 | 直接拼接 WDA URL、执行 UI selector |

## 4. P0 可行性门禁

### 4.1 M0-A：EasyTier iOS XCFramework 与 TUN fd

本门禁验证 v1 内部分发轨的 fd path；选择 App Store 轨时仍需先用它验证 EasyTier Core/peer 基线，再以 4.6 的 M0-E public packetFlow bridge 作为 Release 交付门禁。M0-A 通过不能替代 M0-E。

必须用真机证明：

1. EasyTier v2.6.4 可编译为 `EasyTierFFI.xcframework`。
2. `PacketTunnelProvider` 能在 `setTunnelNetworkSettings` 后提取有效 TUN fd。
3. `run_network_instance` 后调用 `set_tun_fd` 返回 `0`。
4. 美国 EasyTier 节点能看到 iPhone peer。
5. 双向 TCP 流量能从美国节点进入 iPhone TUN 并到达 iPhone 本地 WDA `8100`。

本设计 v1 采用 WireGuard Apple 同款的 fd 提取法（`WireGuardAdapter.tunnelFileDescriptor`）：遍历进程 fd，用 `getpeername` + `CTLIOCGINFO` 匹配 `com.apple.net.utun_control` 找到 TUN fd，再 `dup` 持有：

```swift
var ctlInfo = ctl_info()
withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
        _ = strcpy($0, "com.apple.net.utun_control")
    }
}
for fd: Int32 in 0...1024 {
    var addr = sockaddr_ctl()
    var ret: Int32 = -1
    var len = socklen_t(MemoryLayout.size(ofValue: addr))
    withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            ret = getpeername(fd, $0, &len)
        }
    }
    if ret != 0 || addr.sc_family != AF_SYSTEM { continue }
    if ctlInfo.ctl_id == 0 {
        ret = ioctl(fd, CTLIOCGINFO, &ctlInfo)
        if ret != 0 { continue }
    }
    if addr.sc_id == ctlInfo.ctl_id { return fd }
}
```

早期使用的 `packetFlow.value(forKeyPath: "socket.fileDescriptor")` 是未公开 KVC 路径，iOS 16+ 实测返回 nil（WireGuard 官方已弃用），导致真机启动报 `TUN_FD_UNAVAILABLE`，因此替换为上述遍历方案。选择 fd 直取的理由是 EasyTier v2.6.4 FFI 只接受 fd，且 v1 是内部签名分发。任何取值失败都必须让隧道启动失败并上报 `TUN_FD_UNAVAILABLE`，禁止回退为空 VPN 或伪在线。

App Store 交付轨必须把 EasyTier 改造为基于 `NEPacketTunnelFlow.readPackets/writePackets` 的双向回调桥接，证明背压、取消、内存上限和吞吐后重新评审，并取得所需 Network Extension entitlement；不能把 v1 私有 KVC 实现直接送审。该改造通过后，WDA 仍按第 8 章由 USB/Xcode 单独激活。

### 4.2 M0-B1：公网蜂窝双向访问

验收环境必须同时满足：

- iPhone USB 已拔除；
- Wi-Fi 已关闭；
- 状态栏确认使用 4G/5G；
- 美国服务器与 iPhone 不在同一局域网；
- 美国服务器连续 30 分钟每 5 秒请求一次 `http://<vpn-ip>:8100/status`，成功率不低于 99%；
- 期间主动切换一次飞行模式 30 秒，关闭后 120 秒内恢复同一虚拟 IP；
- 恢复后能创建 WDA session、读取 `/source`、获取 `/screenshot`。

### 4.3 M0-B2：公网 Wi-Fi 与承载切换

验收必须使用可访问公网的普通 Wi-Fi，不能依赖美国服务器所在局域网：

1. iPhone 关闭蜂窝数据，只保留 Wi-Fi；美国服务器连续 30 分钟每 5 秒请求一次 `http://<vpn-ip>:8100/status`，成功率不低于 99%。
2. 在 Wi-Fi-only 下创建 WDA session、读取 `/source`、获取 `/screenshot` 并发送一条测试消息。
3. 保持 EasyTier profile 和虚拟 IP 不变，依次执行 `Wi-Fi -> 4G/5G -> Wi-Fi`；每次切换后 120 秒内恢复 peer 和 `8100/status`。
4. 切换期间若 item 尚未越过 click 边界，可等待恢复或安全失败；若已越过 click 边界且无法验证，必须得到 `unknown`，不得自动再次点击。
5. iOS `NWPathMonitor` 只用于记录承载类型和触发状态采集；不得按 `interfaceType` 拒绝 Wi-Fi，也不得把路径变化当作 WDA 已恢复的证据。

### 4.4 M0-C：WDA 脱离 USB/宿主后的寿命

严格步骤：

1. USB 启动 WDA 并确认虚拟 IP `8100/status` 可访问。
2. 拔掉 USB。
3. 结束 Mac 上的 `xcodebuild`、Appium、go-ios 或其他启动/转发进程。
4. 前 12 小时使用 Wi-Fi-only，后 12 小时使用 4G/5G-only；在第 6、12、18 小时各额外切换一次承载。
5. 连续 24 小时每 30 秒检查 `/status`，每小时创建/删除一次 session 并读取一次 source；每次承载切换允许最多 120 秒恢复窗口。
6. Wi-Fi 和蜂窝阶段各执行至少一次测试消息发送，24 小时末再执行一次。

24 小时内任何“必须重新连接 USB 才能恢复”的情况均判定失败。失败后不允许通过延长重试或把状态改成 online 绕过。

### 4.5 M0-D：WhatsApp selector 与发送口径

固定一台测试 iPhone、一个已 opt-in 的测试号码、`zh_CN` 和 `en_US` 两种系统/WhatsApp 语言，分别执行 20 条消息：

- 20/20 能通过深链进入正确号码会话；
- 20/20 在点击前能读取并校验 composer 内容；
- 20/20 只点击一次发送；
- 20/20 能以“基线之后新增、方向明确、正文相同且 identity 可区分的出站气泡 + composer 清空”判定 `sent`；
- 连续发送相同正文、历史列表滚动、同时出现入站消息或人工触摸时不能误判；证据不唯一时必须为 `unknown`；
- 无效号码必须在点击前判定 `WHATSAPP_RECIPIENT_INVALID`；
- 点击后人为断网必须得到 `unknown`，且系统不得自动重发。

M0 记录保存到 `docs/testing/2026-08-06-ios-easytier-wda-m0.md`，包含设备型号、iOS、WhatsApp、WDA、Xcode、EasyTier 版本、时间窗、原始成功计数和脱敏截图哈希。

### 4.6 M0-E：App Store 网络 Extension 专项（只有选择上架时执行）

App Store 轨必须额外通过：

1. Release 构建不包含 `socket.fileDescriptor` KVC、`mknod`、私有 entitlement 或未声明的动态加载；静态扫描和运行时符号扫描均为零命中。
2. `PacketTunnelProvider` 只通过 6.2.1 定义的 `NEPacketTunnelFlow.readPackets/writePackets` 回调桥接 EasyTier，队列背压、取消、内存上限和异常 stop 都有单测与真机测试；App Store target 对 `set_tun_fd`、`TunnelFileDescriptor.swift` 和 fd KVC 的调用命中数为零。
3. Apple Developer portal 中 App Group、Network Extension entitlement、Push/Background 配置与 bundle IDs 一致；TestFlight 安装后能完成 enrollment、系统 VPN 确认、Wi-Fi-only/蜂窝-only/切换组网。
4. TestFlight/App Store 包仍不能安装、签名或启动 WDA；WDA 仍按第 8.2 节 USB/Xcode 单独激活。App Store 审核是否接受该产品用途是外部发布风险，未获批准不得把 M0-E 标为通过。

## 5. EasyTier 网络详细设计

> 架构基线对齐用户实际部署（OpenWrt/iStoreOS `easytier-core 2.6.4-8428a89d`，单进程 + `config.toml`，`us.hsddns.com` 固定公网服务端）。产品采用**单一共享网络**：`us.hsddns.com` 运行一个 `easytier-core` 作为服务端，所有 iPhone 注册加入同一网络，服务端下发配置。

### 5.1 单一共享网络与 IP 分配

EasyTier 运行**一个**共享网络：

- `network_name`：固定 `wa-ios`（只允许 `[a-z0-9-]`）。
- 网段：`10.168.0.0/16`（65534 个可用地址，容纳 5000 设备 + 服务端 + 预留）。说明：`10.168.168.0/24` 只有 254 个地址，不满足 5000 设备，故按用户命名风格扩大到 `/16`。
- 服务端固定虚拟 IP：`10.168.0.1`（us.hsddns.com）。
- 设备 IP：**顺序递增、不固定绑定**——每次注册/重注册分配当前最大值 +1（`10.168.1.1` 起，如已有 `.2` 则下次必为 `.3`），旧 IP 不复用；服务端 `10.168.0.1` 固定不变。enroll 响应下发当前 IP。
- 分配算法：server 在事务内 `pg_advisory_xact_lock(hashtext('ios-network-ip-v1'))` 取 `MAX(vpn_ip)+1`。启动时必须检查 `10.168.0.0/16` 与美国服务器 VPC、容器、VPN、办公网路由无冲突；有冲突先修改常量再部署，不允许运行时静默换网段。

**WDA `8100` 隔离（共享网络的关键安全约束）**：WDA 无应用层鉴权，必须用 EasyTier ACL（v2.6.4 官方支持）隔离：

1. 只允许 controller 虚拟 IP `10.168.0.1` 访问任意设备 `:8100`；
2. 拒绝设备之间互访（设备只能访问 `10.168.0.1` 的 `:8100`，实际设备不需要访问任何其他节点）；
3. ACL 规则由 controller 渲染进服务端配置并随配置下发/热更新；任何 ACL 缺失时不得把设备标为 online。

ACL 精确语法以 v2.6.4 固定提交实测为准（M0-A 门禁）；若固定版本 ACL 能力不足，追加设备侧防火墙（iPhone `bind_device` 时仅允许 `10.168.0.1` 访问本机 `8100`），并在门禁记录。

### 5.2 密钥和网络名

- `network_name`：固定 `wa-ios`（共享网络，不再按设备区分）。
- `network_secret`：CSPRNG 生成 32 字节后 Base64，**网络级单一 secret**，所有设备共享；服务器侧 `AES-256-GCM(ENCRYPTION_KEY, secret)` 加密存储，iOS 存共享 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）。
- 设备身份不依赖网络隔离：应用层 agent token（每设备唯一）+ 网络层 ACL 双保险；secret 泄漏时 ACL 仍阻止未授权访问 `8100`，但必须按 16.3 告警并评估全量重新 enroll。
- 禁止在浏览器响应、WSS 日志、崩溃日志、指标标签或截图元数据中出现 secret。

### 5.3 美国端 EasyTier 配置（服务端单实例）

`us.hsddns.com` 只运行**一个** `easytier-core`（systemd 常驻、崩溃自动拉起），配置为单文件：

```text
/etc/whatsapp-ai/easytier.toml
```

`ios-controller` 只允许执行固定绝对路径 `/opt/whatsapp_ai/vendor/easytier/v2.6.4/easytier-core`，参数固定为 `--config-file /etc/whatsapp-ai/easytier.toml --disable-env-parsing`。配置由结构化字段渲染，禁止把用户输入拼成命令：

```toml
instance_name = "wa-ios-server"
hostname = "us-controller"
ipv4 = "10.168.0.1/16"
dhcp = false
listeners = ["udp://0.0.0.0:11010", "tcp://0.0.0.0:11010", "wg://0.0.0.0:11011"]
rpc_portal = "127.0.0.1:15888"

[network_identity]
network_name = "wa-ios"
network_secret = "value-loaded-from-encrypted-store"

[flags]
enable_ipv6 = false
use_smoltcp = true
bind_device = true
mtu = 1380
```

- 参考用户实际配置（`new.hsddns.com`/`old.hsddns.com` 的 OpenWrt 包 `2.6.4-8428a89d`）：listener 采用 TCP/UDP/WG 同端口；**产品服务端不启用 KCP/QUIC/zstd**（方案 6.2 排除，控制内存与攻击面）。
- `rpc_portal` 只绑定 `127.0.0.1`（用户配置绑 `0.0.0.0` 属个人网络，产品禁止公网 RPC，见 5.5）。
- 设备上线不需要修改服务端配置（设备作为 peer 连入）；**ACL 变更**（设备退役/禁用）通过 RPC 热更新或重启服务端应用，见 9.3。
- 服务端配置含 `network_secret`，controller 只从加密存储解密后写入；日志与 API 响应必须脱敏。
- 日志脱敏验收沿用：EasyTier fork 必须移除 `cfg.dump()` / `global_ctx.config.dump()` 的完整 dump，用唯一 canary secret 启动最小实例扫描 stdout/stderr/unified log，任一输出包含 canary 或明文 secret 即发布失败。

### 5.4 iPhone EasyTier 配置

主 App 根据服务端下发的结构化配置生成 TOML，不接受服务端直接下发任意 TOML：

```toml
instance_name = "wa-ios-<device-id>"
hostname = "iphone-<device-id>"
ipv4 = "10.168.1.5/16"
dhcp = false
listeners = []

[network_identity]
network_name = "wa-ios"
network_secret = "value-read-from-shared-keychain"

[[peer]]
uri = "udp://us.hsddns.com:11010"

[[peer]]
uri = "tcp://us.hsddns.com:11010"

[flags]
enable_ipv6 = false
use_smoltcp = true
bind_device = false
mtu = 1380
```

只路由 `10.168.0.0/16`，不接管默认互联网流量。`NEIPv4Settings`：

```swift
let ipv4 = NEIPv4Settings(
    addresses: [config.iphoneIPv4],
    subnetMasks: ["255.255.0.0"]
)
ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.168.0.0",
                                   subnetMask: "255.255.0.0")]
settings.ipv4Settings = ipv4
settings.mtu = 1380
```

### 5.5 防火墙

- 美国服务器安全组/nftables 固定开放 `11010/11011` 的 UDP/TCP（含 WG），并对新连接做速率限制；端口固定，API 动态创建设备无需修改防火墙。
- `rpc_portal` 只监听 `127.0.0.1`，公网不可达；`8100` 不做公网 DNAT，不监听美国公网地址。
- 控制器构造 WDA 地址时必须同时验证：
  1. `vpn_ip` 能用 Go `net/netip` 解析为 IPv4；
  2. IP 在 `10.168.0.0/16`；
  3. IP 等于该设备在数据库登记的唯一 `vpn_ip`；
  4. 端口严格等于 `8100`；
  5. HTTP client 禁用代理和重定向。
- 任何失败返回 `IOS_DEVICE_ADDRESS_INVALID`，不得发起网络请求。

### 5.6 容量与规模设计（5000 设备注册）

目标：系统按 **5000 台设备注册**容量设计，全部设备加入 `wa-ios` 共享网络，`us.hsddns.com` 单服务端承载。

#### 5.6.1 容量核算

| 资源 | 容量 | 5000 设备用量 | 结论 |
|---|---|---|---|
| 虚拟网段 | `10.168.0.0/16`（65534 可用） | 5000 设备 + 服务端 + 预留 | ✅ 约 7.6% |
| 服务端公网端口 | `11010/11011` 固定 | 不变（所有设备连同一服务端） | ✅ |
| 服务端进程 | 1 个 `easytier-core` | 5000 peer 连接 | ⚠️ 见 5.6.3 |
| ios_devices 行 | 无上限 | 5000 + 历史 retired | ✅ |
| 事件表 ios_automation_events | 无上限 | 按任务量增长，需按 tenant 归档 | 见 5.6.5 |

#### 5.6.2 批量注册（enrollment）容量

1. enroll 限流双重维度：来源 IP 每 10 分钟 100 次（宽松防扫）+ 每个 enrollment code 只允许成功一次（防重放）。
2. App 对 429/网络错误指数退避（1s、2s、4s、… 上限 60s），避免 5000 台同时重试打满入口。
3. 批量初始化（8.2 USB 激活）建议分批：管理员按批创建设备（如每批 500），App 注册后立即完成 VPN profile 确认与组网。
4. 生产入口（LB/CDN）按 IP 段限流与代码限流叠加，阈值由部署清单配置。

#### 5.6.3 服务端资源（主要瓶颈）

服务端单进程承载 5000 个 peer 连接：

- **内存**：参考用户全特性单实例实测约 1GB RSS（kcp/quic/zstd/multi_thread 全开）；产品服务端按 6.2 关闭多余特性，基线需 M0-A 实测。每 peer 连接状态（加密上下文、路由、socket 缓冲）估算 50-200KB，5000 peer 约 0.25-1GB；总内存以实测为准。
- **文件描述符**：每 peer 连接至少 1-2 fd，5000 peer 约 0.5-1 万 fd；系统 `ulimit -n` 与 systemd `LimitNOFILE` 必须 ≥ 65535。
- **带宽/CPU**：所有 WDA 流量经服务端转发（controller -> 设备），按消息速率压测；多线程 tokio（multi_thread）按核数配置。
- **单点与恢复**：服务端进程崩溃 = 全部设备断连；systemd 自动拉起后从配置恢复监听，controller 在 `8100` probe 恢复前不得把设备标为 online（避免伪在线）。

#### 5.6.4 controller 在 5000 设备下的设计

1. **reconcile 分页**：`GET /devices?controllerId=` 支持分页（limit 500/页）；controller 每 30 秒一轮、每 tick 处理一页，按 configVersion 比对设备清单与 ACL，禁止单次全量拉取 5000 行造成周期抖动。
2. **ACL 热更新限速**：设备启用/禁用/退役对应的 ACL 变更通过 loopback RPC 更新，默认 20 条/s（可配），失败按设备退避（5s、10s、… 上限 5min）。
3. **`IOS_MAX_PARALLEL_DEVICES` 语义**：是“同时执行发送任务的设备上限”。5000 设备时按服务器核数配置（建议 4-8×核数，如 64 核 → 256），默认 20 只作为保守起点；并发上限不影响已组网设备的 WDA 探活。
4. **controller 分片**：服务端单进程承载不足（内存/带宽实测超预算）时，用 `controller_id`（us-1、us-2、…）分片，每片独立 `easytier-core` 服务端与网段子池（如 `10.168.0.0/17`、`10.168.128.0/17`），每片 2500 设备；server 按分片分配新设备。
5. **探活节流**：每设备 WDA probe 固定间隔（如 15s）与 5000 设备叠加时，controller 内部按设备分片串行 probe，避免探活风暴。

#### 5.6.5 监控与告警

每 15 秒采集：服务端 peer 数、进程 RSS、总内存、监听端口、reconcile 周期耗时、分页拉取失败率；每设备：EasyTier peer 状态、WDA 8100 可达率、lease 领取延迟。

告警阈值（部署清单可调）：总内存 > 70%、peer 数与 enabled 设备数偏差 > 5%、reconcile 周期 > 60s、enroll 429 率 > 1%、ACL 热更新失败率 > 1%。

#### 5.6.6 实测与验证

1. M0-A 通过后，用固定提交 `v2.6.4-8428a89d` 的服务端二进制在目标服务器实测单实例基线（RSS、fd、启动耗时）及 100/1000/5000 模拟 peer 下的内存与带宽，记录到容量文档。
2. 5000 设备容量验收：模拟 5000 台注册（DB 造数 + 假 WDA），验证 IP 分配唯一、reconcile 分页、ACL 热更新、enroll 限流、监控指标达标；该压测属 M4 验收一部分，不替代 M0 真机门禁。

## 6. iOS 工程设计

### 6.1 目录和文件职责

实施时创建以下目录，文件不得合并成单个大型 Swift 文件：

```text
WhatsAppDeviceAgent/
├── WhatsAppDeviceAgent.xcodeproj
├── Configs/
│   ├── Base.xcconfig                  # iOS 16.4、Swift、统一 bundle 前缀
│   ├── Debug.xcconfig
│   └── Release.xcconfig
├── Vendor/EasyTier/
│   ├── EasyTierFFI.xcframework        # 构建产物，不手工修改
│   ├── include/easytier_ffi.h         # 人工维护、symbol test 校验
│   ├── LICENSE-LGPL-3.0
│   └── SOURCE_COMMIT                  # 固定 EasyTier commit
├── Shared/
│   ├── Models/AgentConfig.swift       # Codable 配置及严格校验
│   ├── Models/AgentStatus.swift       # 上报状态枚举
│   ├── Security/SharedKeychain.swift  # token/secret，App + Extension 共用
│   ├── Storage/AppGroupStore.swift    # 非秘密配置和 extension 状态快照
│   ├── Networking/AgentAPIClient.swift
│   ├── Networking/AgentWebSocket.swift
│   └── Logging/RedactingLogger.swift
├── WhatsAppDeviceAgent/
│   ├── WhatsAppDeviceAgentApp.swift
│   ├── AppModel.swift                 # UI 状态协调，不包含 FFI
│   ├── Enrollment/EnrollmentService.swift
│   ├── VPN/VPNManager.swift           # NETunnelProviderManager 配置/启停
│   ├── Views/EnrollmentView.swift
│   ├── Views/DeviceStatusView.swift
│   ├── Info.plist
│   └── WhatsAppDeviceAgent.entitlements
├── PacketTunnel/
│   ├── PacketTunnelProvider.swift     # start/stop/sleep/wake 生命周期
│   ├── EasyTierBridge.swift           # Swift 对 C ABI 的唯一入口
│   ├── EasyTierConfigBuilder.swift    # 结构化字段 -> TOML
│   ├── TunnelFileDescriptor.swift     # KVC 提取 + dup + close
│   ├── PacketFlowBridge.swift          # App Store target 的 public packetFlow 双向桥
│   ├── TunnelStatusReporter.swift     # collect_network_infos -> App Group
│   ├── Info.plist
│   └── PacketTunnel.entitlements
├── WhatsAppDeviceAgentTests/
│   ├── AgentConfigTests.swift
│   ├── EasyTierConfigBuilderTests.swift
│   ├── EnrollmentServiceTests.swift
│   └── VPNManagerTests.swift
└── PacketTunnelTests/
    ├── EasyTierBridgeTests.swift
    └── TunnelLifecycleTests.swift

third_party/easytier/                 # EasyTier v2.6.4 源码固定提交/子模块
scripts/build-easytier-ios.sh         # 设备+模拟器静态库和 XCFramework
scripts/verify-easytier-ffi-symbols.sh
```

默认标识固定为：

```text
App bundle ID       com.whatsappai.deviceagent
Extension bundle ID com.whatsappai.deviceagent.packet-tunnel
App Group           group.com.whatsappai.deviceagent
Keychain group      $(AppIdentifierPrefix)com.whatsappai.deviceagent.shared
```

实际 Apple Team 可在签名配置中覆盖 bundle 前缀，但 App、Extension、App Group、Keychain group 必须成组修改并由测试校验一致。

工程配置固定 `EASYTIER_IO_MODE=fd`（Development/Ad Hoc）或 `EASYTIER_IO_MODE=packet_flow`（App Store/TestFlight Release）；Swift `EasyTierBridge` 和 Rust FFI 入口均按该编译定义选择实现，不能在一个 target 运行期猜测或回退到另一种模式。

### 6.2 EasyTier fork 的最小修改

固定修改以下上游文件，禁止顺带重构 EasyTier：

1. `easytier-contrib/easytier-ffi/Cargo.toml`
   - `[lib] crate-type` 改为 `['staticlib', 'cdylib']`。
   - `easytier` 依赖关闭默认 features，只启用 `wireguard,websocket,smoltcp,tun`，排除 v1 不需要的 KCP、QUIC、fake TCP、magic DNS、zstd 和 socks5。
2. `easytier-contrib/easytier-ffi/src/lib.rs`
   - 保留现有 ABI；补充空指针检查，禁止跨 FFI `assert!` 导致进程 abort。
   - `set_tun_fd`、`run_network_instance`、`retain_network_instance` 的所有错误写入 `ERROR_MSG`。
   - 新增 Rust 单测覆盖 null、重复 instance、无效 fd、释放字符串。
3. `easytier/src/core.rs` 与 `easytier/src/instance/instance.rs`
   - 移除 CLI 和 FFI/`Instance::new` 路径的完整 config dump，或调用统一脱敏 dump；只记录配置路径、instance name 和 source，不改变网络行为。

Internal 轨的 `easytier_ffi.h` 基础 ABI 必须精确为：

```c
#ifndef EASYTIER_FFI_H
#define EASYTIER_FFI_H
#include <stddef.h>
#include <stdint.h>

typedef struct ETKeyValuePair {
    const char *key;
    const char *value;
} ETKeyValuePair;

int32_t parse_config(const char *cfg_str);
int32_t run_network_instance(const char *cfg_str);
int32_t set_tun_fd(const char *inst_name, int32_t fd);
int32_t retain_network_instance(const char *const *inst_names, size_t length);
int32_t collect_network_infos(ETKeyValuePair *infos, size_t max_length);
void get_error_msg(const char **out);
void free_string(const char *value);
#endif
```

`collect_network_infos` 返回的每个 `key`、`value` 以及 `get_error_msg` 返回的字符串都必须在 Swift 复制后调用 `free_string`；遗漏任一释放视为测试失败。

6.2.1 的三个 `set_packet_flow_io`、`push_packet_flow_packet`、`close_packet_flow_io` 作为同一 header 的附加 ABI，使用固定 `int32_t` 错误码和 callback 签名；symbol test 必须按 target 同时核验基础 ABI 与 public bridge ABI，不能靠 Swift 私有声明绕过 header。

### 6.2.1 App Store 轨的 public packetFlow bridge

App Store target 不调用 `packetFlow.value(forKeyPath:)`、`socket.fileDescriptor`、`dup` 或任何 TUN fd API。EasyTier fork 新增一个与 fd 轨并列的 `PacketFlowTunnel`，仍实现现有 `Tunnel` 的 `ZCPacketStream + ZCPacketSink`，只替换 `virtual_nic.rs` 中的 `TunStream/TunAsyncWrite`：

```c
typedef int32_t (*ETPacketOutputCallback)(
    const uint8_t *bytes, size_t length, uint32_t ip_version, void *context);

enum { ET_IO_OK = 0, ET_IO_EAGAIN = -11, ET_IO_EINVAL = -22, ET_IO_ENOENT = -2 };

int32_t set_packet_flow_io(const char *inst_name,
                           ETPacketOutputCallback output,
                           void *context);
int32_t push_packet_flow_packet(const char *inst_name,
                                const uint8_t *bytes, size_t length,
                                uint32_t ip_version);
int32_t close_packet_flow_io(const char *inst_name);
```

实现约束：

1. `push_packet_flow_packet` 只接受完整 IPv4 packet（`ip_version=4`，首 nibble 为 4，长度 20..65535）；Swift 传入的 `protocols` 不是可信输入，必须与首 nibble 交叉校验。v1 EasyTier `enable_ipv6=false`，IPv6 返回 `-EINVAL`。
2. Rust 侧为每个 instance 建立输入/输出 bounded channel，容量固定为最多 1024 个 packet 且总 payload 不超过 2 MiB；`push` 成功前复制 bytes，Swift 可以在返回后释放 `Data`。队列满返回 `-EAGAIN`，非法参数返回 `-EINVAL`，instance 不存在/已关闭返回 `-ENOENT`。
3. `set_packet_flow_io` 对 null callback/context、重复注册或已经关闭的 instance 返回 `-EINVAL`/`-ENOENT`，注册 callback 前先创建 channel；Rust 输出 sink 从 peer 收到 packet 后调用 callback。callback 只在调用期间借用 `bytes`，Swift 必须同步复制；返回 `0` 表示已入 Swift 队列，`-EAGAIN` 表示 Rust 保留同一 packet 并在 5 秒内重试，其他负值关闭 tunnel。Rust 不把 Swift 指针写入磁盘或跨 stop 生命周期保存。
4. Swift 用 `Unmanaged<PacketFlowBridge>.passRetained(...).toOpaque()` 作为 context；`close_packet_flow_io` 先禁止新 push，再关闭 channel，等待所有 in-flight callback 返回，最后销毁 context；函数返回后 Swift 才 `release()`。该函数不能从 callback 内调用。重复 close 返回 0，保证 `stopTunnel` 幂等。
5. `PacketFlowBridge.swift` 在 `startTunnel` 完成 `setTunnelNetworkSettings` 后启动两个受控循环：
   - `readPackets` 循环只在上一批全部成功 push 后继续读取；遇到 `-EAGAIN` 保留未发送批次并每 10 ms 重试，Swift backlog 上限 2 MiB，超过 5 秒仍未清空则 `cancelTunnelWithError(EASYTIER_PACKET_BACKPRESSURE)`。
   - Rust callback 只把复制后的 packet 放入 Swift output queue；队列同样限制 2 MiB，drain 每批最多 64 个 packet 调用 `packetFlow.writePackets`，返回 false 立即停止 tunnel。
6. Swift output callback 不能同步 dispatch 到 `PacketTunnelProvider` 的 stop queue；只做锁内 copy/enqueue 和异步 drain，避免 `close_packet_flow_io` 与 callback 死锁。stop 顺序为：标记 stopping -> 停止 read 循环 -> `close_packet_flow_io` -> 清空两个队列 -> 写入 App Group `stopped` -> completion。
7. `instance_manager.rs` 新增 `set_packet_flow_io/push_packet_flow_packet/close_packet_flow_io`，与 `set_tun_fd` 使用同一 instance name map；`instance.rs` 的移动 NIC sender 用枚举区分 `Fd` 与 `PacketFlow`，`virtual_nic.rs` 新增 `run_for_packet_flow` 并复用已有 peer-to-NIC/NIC-to-peer 两个转发 task。输入 wrapper 用 `ZCPacket::new_from_buf(..., ZCPacketType::NIC)` 构造与现有 `TunStream` 相同的 payload offset，输出 wrapper 复用 `TunZCPacketToBytes` 的无 packet-information 分支。不得在 Swift 侧重写 EasyTier 路由、加密或 peer 逻辑。
8. App Store Release scheme 只链接 packetFlow bridge；`TunnelFileDescriptor.swift` 和 fd symbols 不加入该 target。静态扫描必须对 KVC key、`socket.fileDescriptor`、`mknod`、私有 entitlement 和 `set_tun_fd` 调用为零命中；Internal Development/Ad Hoc scheme 才允许 fd path。

该 bridge 的单测必须覆盖：packet copy 后 Rust 不再访问 Swift buffer、队列满/恢复、`writePackets=false`、callback 与 close 并发、重复 stop、IPv4/IPv6/畸形 packet、2 MiB 上限和 5 秒 backpressure timeout。真机 M0-E 还要验证 WDA `8100` 的 TCP 建连、Wi-Fi-only、蜂窝-only 和承载切换；模拟器通过不能替代真机证据。

### 6.3 XCFramework 构建

`scripts/build-easytier-ios.sh` 必须：

1. 核验 `third_party/easytier` HEAD 等于固定 commit，dirty 时退出。
2. 使用仓库锁定 Rust 1.95 和 `Cargo.lock --locked`。
3. 构建 `aarch64-apple-ios`、`aarch64-apple-ios-sim`、`x86_64-apple-ios`。
4. 用 `lipo` 合并两个 simulator 静态库。
5. 用 `xcodebuild -create-xcframework` 生成唯一产物。
6. 用 `nm -gU` 与 header 比对基础 ABI 七个函数和 public bridge 三个函数；缺失、额外未声明导出或架构不一致均失败。
7. 输出 SHA-256 到 `EasyTierFFI.xcframework.sha256`。

开发验证命令：

```bash
rtk bash scripts/build-easytier-ios.sh
rtk bash scripts/verify-easytier-ffi-symbols.sh
rtk xcodebuild -project WhatsAppDeviceAgent.xcodeproj \
  -scheme WhatsAppDeviceAgent -sdk iphonesimulator -configuration Debug build
```

### 6.4 配置存储

共享 Keychain 只保存：

| key | 内容 |
|---|---|
| `agent.device_token` | 设备 Bearer token |
| `agent.network_secret` | EasyTier network secret |

App Group `Library/Application Support/agent-config.json` 保存非秘密字段：`schemaVersion`、`configVersion`、`deviceId`、`networkName`、slot、两个虚拟 IP、CIDR、relay host/port、server base URL、更新时间。

写配置必须执行：写临时文件 -> `fsync` -> 原子 rename。Extension 读取后执行 schema、IP、端口、host、configVersion 校验；失败不启动 VPN。

### 6.5 Packet Tunnel 生命周期

Internal Development/Ad Hoc target 的 `PacketTunnelProvider.startTunnel` 固定顺序：

1. 在专用串行队列检查当前状态必须为 `stopped`。
2. 读取并校验 App Group 配置和共享 Keychain secret。
3. 构造 `NEPacketTunnelNetworkSettings`，只包含共享网段 `10.168.0.0/16` 路由（见 5.4）。
4. `setTunnelNetworkSettings` 成功后提取并 `dup` TUN fd。
5. `EasyTierConfigBuilder` 生成 TOML，调用 `parse_config`；失败关闭 fd。
6. 调用 `run_network_instance`；失败关闭 fd。
7. 调用 `set_tun_fd(instanceName, ownedFD)`；失败调用 `retain_network_instance(NULL, 0)` 再关闭 fd。
8. 每秒调用一次 `collect_network_infos`，最多等待 30 秒，直到对应 instance 的 `running=true`、`error_msg` 为空且至少一个 peer 出现。
9. 写入 App Group 状态 `connected` 后调用 completion；超时则完整 stop 并返回错误。
10. 连接后每 15 秒采集一次运行信息，只保存 peer 数、running、错误码和时间，不保存完整路由/peer JSON。

`stopTunnel` 固定顺序：

1. 停止状态 timer。
2. 调用 `set_tun_fd(instanceName, -1)` 清理移动 TUN。
3. 调用 `retain_network_instance(NULL, 0)` 删除全部 instance。
4. `close(ownedFD)`，并把字段置为 `-1`，保证只关闭一次。
5. App Group 状态写 `stopped`，调用 completion。

App Store target 在第 4 步不提取 fd，而是在 `setTunnelNetworkSettings` completion 中调用 `PacketFlowBridge.start`，按第 6.2.1 节启动 `readPackets`、Rust input queue 和 output callback；其 stop 顺序为停止 read -> `close_packet_flow_io` -> 清空队列 -> 写状态 -> completion。两种 target 共享配置、状态和 probe 逻辑，但构建时不能同时选择两种 packet I/O 实现。

`sleep` 只停止统计 timer，不销毁 instance；`wake` 恢复 timer并检查 peer，30 秒仍无 peer 时调用 `cancelTunnelWithError` 触发系统重连。

### 6.6 VPN profile 和首次系统确认

主 App 使用 `NETunnelProviderManager` 保存唯一 profile：

- `providerBundleIdentifier = com.whatsappai.deviceagent.packet-tunnel`
- `serverAddress = EasyTier`
- `providerConfiguration` 只放 `schemaVersion` 和 `configVersion`，不放 secret/token
- `isOnDemandEnabled = false`（默认关闭 on-demand：`NEOnDemandRuleConnect` 无条件自动连接会干扰用户手机上其他代理/VPN，本 App 的 VPN 完全由用户/App 手动启动）
- `onDemandRules = []`

首次保存 VPN profile 时 iOS 会弹系统 VPN 配置确认，这是一次性设备初始化确认；它与 WhatsApp 每条消息的发送确认无关。发送阶段不要求用户点击。

### 6.7 主 App 页面

App 只做两个实际页面：

1. `EnrollmentView`
   - 输入平台 HTTPS 地址；注册码支持**扫码**（AVFoundation 二维码）或手动输入；
   - 明确校验 URL scheme 必须为 HTTPS，开发构建只允许 `http://127.0.0.1`；
   - 注册成功后保存 token/secret、保存 VPN profile、请求首次系统确认。
2. `DeviceStatusView`
   - 展示设备名、configVersion、VPN 状态、虚拟 IP、peer 数、最近错误、App API 状态；
   - 提供启动/停止 VPN 图标按钮和重新注册命令；重新注册必须使用管理员新签发的 enrollment code，不能用旧 token 自助绕过禁用；
   - 不展示 secret、token、WDA URL，不提供消息发送入口。

App 无法读取真实 UDID。UDID 在 USB 初始化时由 Mac 获取并录入平台；App 自己生成随机 `installationId`，只上传其 SHA-256 用于绑定检查。

### 6.8 iOS 后台边界

普通 iOS App 的 `URLSessionWebSocketTask` 不能保证在后台永久存活。实现必须遵守：

- App 前台时连接设备 WSS，每 20 秒发送 heartbeat。
- App 进入后台时发送一次 `app:suspended`，随后允许 WSS 断开。
- Packet Tunnel 持续运行并把状态写入 App Group，但不承担群发任务和业务 WSS。
- server 在 60 秒无 App heartbeat 后只把 `appChannel` 标为 stale，不能据此把 VPN/WDA 判 offline。
- `ios-controller` 的 WDA 主动探活才是远程控制在线判据。

## 7. iOS Agent HTTPS/WSS 协议

### 7.1 注册流程

1. 租户管理员在平台「移动设备」页点「创建移动设备」，平台生成注册码并展示**二维码**（10 分钟有效；重新生成旧码失效）；App 用**扫码**或手动输入注册码。
2. server 只保存 code 的 SHA-256（表 `tenant_enrollment_codes`）；浏览器只看到 code，不看到 network secret。
3. App 调用 `POST /api/ios-agent/v1/enroll`（携带注册码 + 持久化 installationId + 设备信息 + platform）。`installationId` 由 App 生成并写入 Keychain，**同一台手机永远一致**（重装不变），平台按它 upsert——注册/登录**始终只有一行设备数据**。
4. server 只按 code hash 找**租户**，不信任请求中的 tenant/device ID。
5. 成功事务内：按 `installationIdHash` **存在则更新、不存在则新建** `mobile_devices` 记录；虚拟 IP 按 5.1 **顺序递增**（每次注册变化）；生成 32 字节 device token，仅本次返回明文 token/secret。
6. App 保存 Keychain 和 VPN profile，随后调用 status API；设备出现在平台设备列表（同一手机始终一行）。

enrollment code 使用 CSPRNG 生成 80 bit 后按 Crockford Base32 编成 16 个字符，展示为四组；服务端比较前移除连字符并转大写，只保存 SHA-256。code 有效期 10 分钟，同一设备生成新 code 会让旧 code 立即失效。公网入口 enroll 限流按 5.6.2 双重维度执行（来源 IP 每 10 分钟 100 次 + code 一次成功）；“不存在、已过期、已消费、设备不可注册”统一返回 `IOS_ENROLLMENT_INVALID` 和相同 HTTP status/message，避免 code 枚举。

enroll 成功响应可能在 App 保存 Keychain 前丢失，因此恢复路径必须确定：App 不重试已经消费的 code，也不能从 config API 取回明文 token；管理员重新生成租户注册码（enrollment-code 接口），App 再次 enroll。新 enroll 原子地替换 installation hash、生成新 token并返回当前 network secret；旧 token 立即 401。retired 设备永远拒绝重新 enroll；disabled 设备只有 `revoke_required=false` 时才能签发新 code，成功 enroll 后转 `enabled=true/status=vpn_connecting`，等待 controller reconcile 和完整 probe。network secret 疑似泄漏时不得走重新 enroll，必须 retire 并创建新 device/network。

注册请求：

```json
{
  "enrollmentCode": "9C4K-7Q2M-P8RX-H5TW",
  "installationId": "5c5e52a6-b650-4dab-82ea-f02b0600eb32",
  "appVersion": "1.0.0",
  "osVersion": "18.6",
  "deviceModel": "iPhone17,2",
  "locale": "zh_CN",
  "platform": "ios"
}
```

成功响应 `201`：

```json
{
  "deviceId": "24-char-text-id",
  "deviceToken": "one-time-raw-token",
  "config": {
    "schemaVersion": 1,
    "configVersion": 1,
    "networkName": "wa-ios",
    "networkCIDR": "10.168.0.0/16",
    "iphoneIPv4": "10.168.1.5",
    "relayHost": "us.hsddns.com",
    "relayPort": 11010,
    "networkSecret": "one-time-network-secret"
  }
}
```

响应字段中的两个 `one-time-*` 表示一次性明文语义，不是生产固定值。HTTP access log 必须对该路由禁用 body 记录。

### 7.2 设备 API

| 方法 | 路径 | 说明 |
|---|---|---|
| `POST` | `/api/ios-agent/v1/enroll` | 一次性 code 注册，无 Bearer |
| `GET` | `/api/ios-agent/v1/config` | Bearer 取当前配置；用于配置轮换 |
| `POST` | `/api/ios-agent/v1/status` | Bearer 上报 App/Extension 快照 |
| `POST` | `/api/ios-agent/v1/token/rotate` | Bearer 轮换 token，旧 token 立即失效 |
| `GET` upgrade | `/api/ios-agent/v1/ws` | Bearer WSS，仅前台状态与轻量命令 |

设备 token 只放 `Authorization: Bearer` header，不放 URL/query。数据库保存 `SHA-256(token)` 的小写十六进制，不保存原文。
`GET /config` 只返回非秘密字段和 `configVersion`，永远不返回 `networkSecret` 或任何 token；network secret 变更只能通过管理员创建新 device/新 enrollment 完成。App 发现 Keychain secret 缺失、配置版本不匹配或解密失败时进入 `enrollment_required`，不能把旧配置拼接后继续组网。
token rotate 成功后旧 token 立即失效；若响应在 App 写入 Keychain 前丢失，不自动重试旧 token，管理员必须签发新 enrollment code 走 7.1 的恢复路径。该取舍避免在 server 保存第二份明文 token 或建立长期双 token 窗口。

### 7.3 WSS envelope

所有文本帧：

```json
{
  "v": 1,
  "type": "agent:heartbeat",
  "msgId": "installation-id:monotonic-sequence",
  "sentAt": "2026-08-06T10:00:00Z",
  "payload": {}
}
```

允许类型：

| 类型 | 方向 | payload |
|---|---|---|
| `agent:hello` | App -> server | app/iOS/model/locale/configVersion |
| `agent:heartbeat` | App -> server | foreground、VPN、peerCount、extension timestamp |
| `agent:status` | App -> server | 状态变化和稳定错误码 |
| `server:ack` | server -> App | `ackedMsgId` |
| `server:config_changed` | server -> App | 新 configVersion，App 随后 GET config |
| `server:diagnostic_request` | server -> App | `requestId`，只返回无敏感诊断 |
| `server:disconnect` | server -> App | reason |

群发 `task:dispatch` 明确不在此协议中。server 对每个 device 只保留一个 WSS；新连接替换旧连接。最大帧 64 KiB、读超时 45 秒、写超时 5 秒、send buffer 16；慢客户端断开。

WSS close code：`4001` token 无效、`4002` 被新连接替换、`4003` 设备禁用、`4004` 协议/帧非法。

## 8. WDA 首次激活与运行 SOP

### 8.1 前置条件

- 付费 Apple Developer Program 账号；免费 7 天签名不满足长期运行。App Store 主 App 的发行账号不替代 WDA Runner 的开发者签名。
- Mac 上固定 Xcode 版本和 WDA v16.1.5。
- iPhone 开启锁屏密码、开发者模式，系统/WhatsApp locale 只允许 M0 验证过的 `zh_CN` 或 `en_US`。
- iPhone 长期供电，关闭自动锁定和低电量模式；设备保持解锁受管状态。
- 官方 WhatsApp 已登录，并且测试号码有明确 opt-in。

### 8.2 一次性 USB 激活

主 App 有两种安装轨，但 WDA 激活步骤完全相同：

| 安装轨 | 主 App 安装 | WDA 安装/启动 |
|---|---|---|
| v1 内部分发 | Xcode Development/Ad Hoc/企业包 | 同一受控 Mac + Xcode + USB，独立签名 WDA Runner |
| App Store | App Store/TestFlight 公共发行包 | 仍由受控 Mac + Xcode + USB 配对并启动独立 WDA Runner；App Store 包不能做这一步 |

1. USB 连接，完成“信任此电脑”和开发者模式重启确认。
2. 按安装轨安装主 App；首次运行完成 enrollment 和 VPN profile 系统确认。App Store 包只能使用已经通过公共 API/entitlement 审核的 Packet Tunnel 构建。
3. 平台创建设备，录入 USB 工具获得的 UDID；App 完成 enrollment 并启动 EasyTier。
4. WDA 固定 fork 使用独立 bundle：`com.whatsappai.WebDriverAgentRunner`。
5. Xcode 为 `WebDriverAgentRunner` 签名并对指定 UDID 执行测试；该动作由 Mac 的 XCTest 服务完成，不由主 App 完成。
6. 美国控制器通过虚拟 IP 请求 `/status`；此处禁止用 USB 端口转发结果代替。
7. 结束 Mac 上的 `xcodebuild`、Appium、go-ios 或其他启动/转发进程，保持 USB 拔除，按 M0-C 先测 Wi-Fi-only 再测 4G/5G-only。

示例启动命令中的 Team 和 UDID 必须来自本地签名配置，不写进仓库：

```bash
rtk xcodebuild -project third_party/WebDriverAgent/WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination 'id=DEVICE_UDID_FROM_XCODE' \
  test
```

`DEVICE_UDID_FROM_XCODE` 是运维现场输入，不是数据库字段猜测或示例真实设备号。

### 8.3 恢复 SOP

`ios-controller` 连续 3 次 WDA probe 失败后：

1. 设备状态转 `recovery_required`。
2. 未越过 click 边界的 leased item 退回 `recovery_required`，保留安全恢复能力。
3. 已越过 click 边界的 item 转 `unknown`，禁止自动重发。
4. 暂停该设备后续领取。
5. 运维现场重新 USB 启动 WDA。
6. 平台 `POST /api/ios-devices/:id/probe` 完整通过 status/session/source/screenshot 后，管理员执行恢复。

VPN 能连接不代表 WDA 能恢复；App Store 或内部分发的主 App 都不能从沙盒中自行安装、签名或启动 XCTest runner。若组织具备受控 Mac，可另行建设 Mac 侧运维服务，但它必须使用 Apple 的开发者配对/测试协议并纳入 USB 初始配对和 `recovery_required` SOP；本设计不把它冒充为 iOS App 能力。

## 9. 美国 `ios-controller` 设计

### 9.1 目录和职责

```text
cmd/ios-controller/main.go                  # config、signal、graceful shutdown
internal/ioscontroller/config.go            # env 严格解析
internal/ioscontroller/controller.go        # reconcile、lease worker、per-device mutex
internal/ioscontroller/network_manager.go   # EasyTier 单进程多实例管理、0600 config、RPC 增删、退避
internal/ioscontroller/platform_client.go   # 内部 API，不直接写数据库
internal/ioscontroller/probe_server.go      # 仅 loopback 的同步设备探活入口
internal/ioscontroller/wda/client.go         # W3C/WDA HTTP envelope 和错误分类
internal/ioscontroller/wda/session.go        # 每设备 session 缓存/重建
internal/ioscontroller/wda/selectors.go      # selector profile 解析
internal/ioscontroller/whatsapp/driver.go    # 发送状态机
internal/ioscontroller/whatsapp/verify.go    # baseline/post-click 校验
internal/ioscontroller/wda_inspection.go     # source/screenshot 仅内存解析，原始内容不落盘
internal/ioscontroller/*_test.go
configs/ios-wda-selectors.json               # 版本/locale selector 数据
deploy/systemd/whatsapp-ai-ios-controller.service
deploy/systemd/whatsapp-ai-easytier.service   # 单进程多实例 easytier-core 常驻
```

控制器不导入 `internal/store`，不直连 PostgreSQL。它只通过 controller internal API 租约领取、提交 phase/result 和状态；server 是唯一任务状态写入者。

### 9.2 环境变量

| 变量 | 必填 | 规则 |
|---|---:|---|
| `IOS_CONTROLLER_ID` | 是 | 固定 `us-1`，只允许 `[a-z0-9-]{1,32}` |
| `IOS_PLATFORM_URL` | 是 | 生产 HTTPS；同机可为 `http://127.0.0.1:8790` |
| `IOS_CONTROLLER_TOKEN` | 是 | 与 server 一致，至少 32 随机字节 |
| `IOS_CONTROLLER_LISTEN_ADDR` | 否 | 默认 `127.0.0.1:8792`；禁止监听非 loopback |
| `IOS_EASYTIER_BIN` | 是 | 必须等于部署允许列表中的绝对路径 |
| `IOS_EASYTIER_STATE_DIR` | 否 | 默认 `/var/lib/whatsapp_ai/ios-networks` |
| `IOS_WDA_SELECTORS` | 否 | 默认 `/opt/whatsapp_ai/configs/ios-wda-selectors.json`，必须为绝对路径 |
| `IOS_MAX_PARALLEL_DEVICES` | 否 | 默认 20（并发任务设备上限，非进程数上限）；5000 设备时按 5.6.4 配置；同设备始终 1 |

### 9.3 EasyTier 单进程多实例管理

- 服务器端只运行**一个** `easytier-core` 进程（systemd 守护、崩溃自动拉起），以 `--config-file /etc/whatsapp-ai/easytier.toml --disable-env-parsing` 启动（5.3）；设备注册后作为 peer 连入同一网络，无需为设备单独创建实例。网络隔离由 EasyTier ACL 限制 `:8100` 仅 controller 可达保证（5.1）。
- controller 每 30 秒从 internal API **分页**拉取 enabled devices（5000 设备时 limit 500/页，见 5.6.4），按 configVersion reconcile：新增/变更的设备只更新服务端 ACL 条目（设备虚拟 IP 注册时已分配；ACL 热更新限速 20/s，见 5.6.4）；每个已 reconcile device 由一个 worker 调用 `/devices/{id}/lease`，同设备 worker 永远只有一个。
- 已 reconcile 设备从 enabled 列表消失时，controller 立即停止该设备的新 lease worker，但不能据此修改 ACL；只有带 generation 的显式 revoke 才从 ACL 移除该设备。现有 worker 若是 click_committed 只完成 renew/result，其他状态立即放弃。该规则保证 disable 的 drain 不会被下一轮 reconcile 绕过；retire 会在事务后立即发显式 revoke。
- controller 重启时不得仅凭本地状态重建 ACL；只有本次从 server enabled 列表重新取得并校验的清单才能应用。未被重新授权的旧设备保持无 ACL 条目，等待持久 revoke 清理。easytier-core 进程由 systemd 常驻，从配置文件恢复监听；controller 在 WDA `8100` probe 恢复前不得把设备标为 online（避免伪在线）。
- 服务端配置/ACL 变更先写临时文件、`fsync`、chmod `0600`、rename，再通过 loopback RPC 热更新（或请求 systemd 重启）应用。
- ACL 更新失败按 1、2、4、8、16、30 秒指数退避；5 分钟内 5 次失败置设备 `recovery_required`。
- 变更该设备 ACL 前先停止其领取；等待其无 click 前 item，再更新 ACL，不影响其他设备。
- SIGTERM 时先停止领取，给已开始项 30 秒收尾；未 click 的归还，已 click 未确认的上报 unknown，再停止 ACL 更新；easytier-core 进程由 systemd 独立托管，controller 退出不影响其运行。

easytier-core 由独立 systemd 服务 `whatsapp-ai-easytier.service` 托管（`deploy/systemd/whatsapp-ai-easytier.service`），`Restart=on-failure`、`LimitNOFILE=65535`、仅 loopback RPC；controller 与 easytier-core 分离，controller 崩溃/重启不影响隧道。controller 的 `whatsapp-ai-ios-controller.service` 与 easytier-core 服务按依赖顺序启动。

systemd 服务给 controller `CAP_NET_ADMIN`/`CAP_NET_RAW` 的最小 capability bounding set，状态目录 `0700`。控制器不得以 root 用户运行，也不得授予 `CAP_MKNOD`。宿主机在启用服务前必须由 root/udev 预先加载 `tun` 模块并创建字符设备 `/dev/net/tun`；controller 只做 ioctl preflight，不创建设备。

`probe_server.go` 只监听 `127.0.0.1:8792`，提供 `GET /health/live`、`GET /health/ready`、带 token 的 `POST /v1/devices/{id}/probe` 和 `POST /v1/devices/{id}/revoke`。revoke body 只允许 `{"generation":N}`，controller 先校验 device ID 格式，再按状态目录下固定的 `<stateDir>/<deviceID>/config.toml` 和 `manifest.json` 路径通过 RPC 删除该设备 EasyTier 实例、删除配置文件并回显相同 generation 的幂等结果；即使本次进程未 reconcile，缺失文件也返回幂等成功。请求不能携带 IP、port、URL 或 secret。manifest 必须记录 device ID、configVersion 和 revokeGeneration，路径不能由请求体拼接。probe 从已 reconcile 的设备表中按 id 取目标，执行 EasyTier process、VPN route、WDA session、source/screenshot 四阶段检查。server 的管理端 probe/recover/revoke handler 通过 `IOS_CONTROLLER_URL` 调用该入口，只有 controller 回显的 generation 与当前数据库一致才清 `revoke_required`。controller 启动时发现 listen address 不是 loopback、`/dev/net/tun` 不存在或 `preflight` ioctl 失败必须退出。

### 9.4 WDA HTTP client

每台设备一个 `http.Client`：

```go
Transport: &http.Transport{
    Proxy: nil,
    DialContext: validatedVPNDialer,
    DisableKeepAlives: false,
    MaxConnsPerHost: 2,
}
CheckRedirect: return http.ErrUseLastResponse
Timeout: 15 * time.Second
```

`validatedVPNDialer` 忽略 URL 中任何非预期 host，实际 dial address 只能是设备记录的虚拟 IP 和 `8100`。响应 body 上限 8 MiB；截图解码后上限 5 MiB；source 上限 8 MiB。

WDA 返回统一解析为：

```go
type Envelope[T any] struct {
    Value     T      `json:"value"`
    SessionID string `json:"sessionId,omitempty"`
}

type WDAErrorValue struct {
    Error   string `json:"error"`
    Message string `json:"message"`
}
```

HTTP 非 2xx或 `value.error` 非空都返回稳定错误。任何日志只记录 deviceId、itemId、route template、耗时、status、error class，不记录 URL query、phone、content、source 或 screenshot。

### 9.5 Selector 配置

`configs/ios-wda-selectors.json` 的 profile 必须同时描述方向、正文和稳定 identity；只匹配 Cell/Other 的宽 selector 永远不合格。文件 schema 固定为：

```json
{
  "schemaVersion": 1,
  "profiles": [
    {
      "id": "whatsapp-v1-zh-en-m0-disabled",
      "enabled": false,
      "locales": ["zh_CN", "en_US"],
      "composer": [
        {"using": "predicate string", "value": "type == 'XCUIElementTypeTextView' AND visible == 1"}
      ],
      "sendButton": [
        {"using": "predicate string", "value": "type == 'XCUIElementTypeButton' AND (name == '发送' OR name == 'Send') AND enabled == 1"}
      ],
      "invalidRecipient": [
        {"using": "predicate string", "value": "type == 'XCUIElementTypeStaticText' AND (name CONTAINS 'invalid' OR name CONTAINS '无效')"}
      ],
      "bubble": {
        "root": [{"using": "predicate string", "value": "visible == 1"}],
        "direction": {
          "using": "predicate string",
          "value": "disabled"
        },
        "text": [{"using": "predicate string", "value": "disabled"}],
        "identity": {
          "stableAttributes": ["identifier", "accessibilityIdentifier", "label", "name"],
          "excludeAttributes": ["frame", "rect", "index", "selected", "focused"],
          "requireOneStableAttribute": true
        }
      }
    }
  ]
}
```

示例 profile 明确 `enabled=false`，其中两个 `disabled` 值不是可运行 selector；它只定义字段形状，禁止直接部署。M0 必须把真机 `/source` 保存为脱敏 fixture，填入真实方向 predicate、正文 descendant selector 和至少一个稳定 identity 属性，再通过 parser 测试锁定实际 WhatsApp 版本与 locale。生产发现没有匹配且 enabled 的 profile 时返回 `WHATSAPP_VERSION_UNSUPPORTED`，禁止使用坐标盲点发送。

解析器对每个可见 bubble 生成：`direction`、NFC 归一化 `text`、稳定属性集合、`subtreeHash` 和 `canonicalBubbleId`。`canonicalBubbleId = SHA-256(profileId || direction || text || stableAttributes || subtreeHash)`；字段按 UTF-8、长度前缀和字典序编码，排除 frame/rect/index 等滚动易变字段。baseline/post-click 使用 canonical ID 多重集合做差集：必须恰好一个新增 outgoing ID、没有新增 incoming ID、没有同正文的第二个新增 outgoing ID、候选为当前最后一个 bubble，且所有 identity 必须稳定；任一条件不满足都返回 `unknown`。若 fixture 无法提供稳定方向或 identity，profile 保持 disabled，不能靠计数猜测。

坐标点击不作为 v1 回退；selector 全部失败即 `SEND_BUTTON_NOT_FOUND`。

### 9.6 单条 WDA 调用序列

以下 route 都在 base `http://<validated-vpn-ip>:8100` 下。

1. 探活：`GET /status`。
2. 创建 session：

```http
POST /session
Content-Type: application/json

{"capabilities":{"alwaysMatch":{"bundleId":"net.whatsapp.WhatsApp","shouldWaitForQuiescence":false}}}
```

3. 打开会话并预填：

```http
POST /session/{sessionId}/url
Content-Type: application/json

{"url":"whatsapp://send?phone=8613800000000&text=URL_ENCODED_TEXT","bundleId":"net.whatsapp.WhatsApp","idleTimeoutMs":3000}
```

`phone` 为校验后的 E.164 去掉 `+`，正文用 `net/url.Values.Encode` 生成，不手拼 query。

4. `GET /session/{sessionId}/source` 检查 invalidRecipient、composer、意外弹窗。
5. `POST /session/{sessionId}/element` 按 profile 顺序找 composer；读取 `/element/{id}/text`。
6. 若 composer 不等于正文：先 `POST /element/{id}/clear`，再 `POST /element/{id}/value`：

```json
{"value":["完整正文"],"frequency":30}
```

7. 再读 text，必须与正文 Unicode NFC 归一化后完全相等。
8. 读取 source，建立 baseline：解析所有可见 bubble 的 direction/text/canonical ID 多重集合、最后 bubble ID 和 source fixture fingerprint；正文相同的 incoming/outgoing 分开计数。
9. 找 send button；确认唯一、visible、enabled。
10. 向 server 提交 `send_click_committed`，server 成功写 `send_clicked_at` 后才继续。
11. 只调用一次 `POST /session/{sessionId}/element/{elementId}/click`，body `{}`。
12. 最多 15 秒、每 500ms 读取 composer/source；只有“composer 清空 + 恰好一个新增 outgoing canonical ID + 无新增 incoming/重复正文候选 + 候选为最后 bubble + fixture fingerprint 未发生不可解释重排”时判 sent。
13. click 请求超时、连接断开、WDA error、验证超时都判 `unknown`，绝不重试 click。

### 9.7 重试规则

| 阶段 | 自动重试 | 结果 |
|---|---:|---|
| `/status`、创建 session、打开深链、找 composer、输入、找按钮，且 `send_clicked_at IS NULL` | 最多 2 次，退避 1s/3s | 仍失败为 failed 或 recovery_required |
| server 提交 click 边界失败 | 不点击 | lease conflict/failed，可安全再领取 |
| click HTTP 调用开始后 | 0 次 | 不能严格确认即 unknown |
| 气泡验证 | 只轮询，不再次点击 | sent 或 unknown |

同一设备由 mutex 串行；不同设备最多按 `IOS_MAX_PARALLEL_DEVICES` 并行。

## 10. 数据库详细设计

实施时同时创建 `docs/database/2026-08-06-ios-wda-broadcast.sql` 和 `internal/store/ios_migrations.go`，SQL 内容保持一致，并由 `Store.migrate` 调用。以下是权威字段定义；禁止改为 UUID 或在 JSONB 中隐藏核心状态字段。

```sql
CREATE TABLE IF NOT EXISTS mobile_devices (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    platform TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios','android')), -- iOS 先行，兼容未来 Android
    installation_id_hash TEXT NOT NULL DEFAULT '',
    agent_token_hash TEXT NOT NULL DEFAULT '',
    vpn_ip INET NOT NULL UNIQUE CHECK (vpn_ip <<= inet '10.168.0.0/16'),
    config_version INTEGER NOT NULL DEFAULT 1 CHECK (config_version > 0),
    controller_id TEXT NOT NULL DEFAULT 'us-1',
    wda_port INTEGER NOT NULL DEFAULT 8100 CHECK (wda_port = 8100),
    status TEXT NOT NULL DEFAULT 'pending_enrollment'
      CHECK (status IN ('pending_enrollment','vpn_connecting','online','busy','offline','recovery_required','disabled','retired')),
    enabled BOOLEAN NOT NULL DEFAULT true,
    revoke_required BOOLEAN NOT NULL DEFAULT false,
    revoke_generation INTEGER NOT NULL DEFAULT 0 CHECK (revoke_generation >= 0),
    revoke_attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (revoke_attempt_count >= 0),
    revoke_next_attempt_at TIMESTAMPTZ,
    revoke_last_error TEXT NOT NULL DEFAULT '',
    retired_at TIMESTAMPTZ,
    ios_version TEXT NOT NULL DEFAULT '',
    device_model TEXT NOT NULL DEFAULT '',
    locale TEXT NOT NULL DEFAULT '',
    app_version TEXT NOT NULL DEFAULT '',
    whatsapp_version TEXT NOT NULL DEFAULT '',
    wda_version TEXT NOT NULL DEFAULT '',
    last_app_seen_at TIMESTAMPTZ,
    last_vpn_seen_at TIMESTAMPTZ,
    last_wda_seen_at TIMESTAMPTZ,
    next_send_not_before TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error_code TEXT NOT NULL DEFAULT '',
    created_by TEXT NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (id, tenant_id)
);

CREATE INDEX IF NOT EXISTS idx_mobile_devices_tenant_status
    ON mobile_devices(tenant_id, status, id);
CREATE INDEX IF NOT EXISTS idx_mobile_devices_controller_enabled
    ON mobile_devices(controller_id, enabled, id);
-- 设备以 installation_id_hash 为唯一标识（App 持久化 installationId）；udid 已移除。
CREATE UNIQUE INDEX IF NOT EXISTS idx_mobile_devices_installation_hash
    ON mobile_devices(installation_id_hash)
    WHERE installation_id_hash <> '' AND status <> 'retired';
CREATE UNIQUE INDEX IF NOT EXISTS idx_mobile_devices_agent_token_hash
    ON mobile_devices(agent_token_hash)
    WHERE agent_token_hash <> '' AND status <> 'retired';

-- 共享网络单一配置（5.2/5.3）：network_name=wa-ios、network_secret 由 server 配置加密存储，
-- 不按设备保存；设备身份由 agent_token_hash + vpn_ip + ACL 共同约束。

CREATE TABLE IF NOT EXISTS mobile_device_enrollment_tokens (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_by TEXT NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (device_id, tenant_id) REFERENCES mobile_devices(id, tenant_id)
);
CREATE INDEX IF NOT EXISTS idx_mobile_enrollment_device_active
    ON mobile_device_enrollment_tokens(device_id, expires_at DESC)
    WHERE consumed_at IS NULL;

-- 租户级注册码（7.1 调整：平台生成租户注册码，App 注册自动归入该租户并创建设备；
-- 可复用，重新生成旧码失效）。mobile_device_enrollment_tokens 为旧设备级注册码，新流程不再使用。
CREATE TABLE IF NOT EXISTS tenant_enrollment_codes (
    tenant_id TEXT PRIMARY KEY REFERENCES tenants(id),
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_by TEXT NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ios_broadcast_tasks (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id),
    created_by TEXT NOT NULL REFERENCES users(id),
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    content TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued'
      CHECK (status IN ('queued','running','paused','completed','completed_with_errors','canceled')),
    total_count INTEGER NOT NULL CHECK (total_count BETWEEN 1 AND 100),
    pending_count INTEGER NOT NULL,
    sent_count INTEGER NOT NULL DEFAULT 0,
    failed_count INTEGER NOT NULL DEFAULT 0,
    unknown_count INTEGER NOT NULL DEFAULT 0,
    canceled_count INTEGER NOT NULL DEFAULT 0,
    min_delay_ms INTEGER NOT NULL DEFAULT 8000 CHECK (min_delay_ms BETWEEN 5000 AND 300000),
    max_delay_ms INTEGER NOT NULL DEFAULT 15000 CHECK (max_delay_ms BETWEEN min_delay_ms AND 600000),
    scheduled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancel_requested_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, idempotency_key),
    UNIQUE (id, tenant_id)
);
CREATE INDEX IF NOT EXISTS idx_ios_tasks_tenant_page
    ON ios_broadcast_tasks(tenant_id, created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS ios_broadcast_task_items (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal > 0),
    recipient_e164 TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
      CHECK (status IN ('pending','leased','preparing','click_committed','sent','failed','unknown','recovery_required','canceled')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 3),
    not_before TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_owner TEXT NOT NULL DEFAULT '',
    lease_token TEXT NOT NULL DEFAULT '',
    lease_started_at TIMESTAMPTZ,
    lease_until TIMESTAMPTZ,
    baseline_hash TEXT NOT NULL DEFAULT '',
    post_click_hash TEXT NOT NULL DEFAULT '',
    send_clicked_at TIMESTAMPTZ,
    verified_at TIMESTAMPTZ,
    resolution_source TEXT NOT NULL DEFAULT 'automatic'
      CHECK (resolution_source IN ('automatic','manual_confirm_sent','manual_confirm_not_sent')),
    error_code TEXT NOT NULL DEFAULT '',
    error_detail TEXT NOT NULL DEFAULT '',
    duration_ms INTEGER NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (task_id, recipient_e164),
    UNIQUE (task_id, ordinal),
    FOREIGN KEY (task_id, tenant_id) REFERENCES ios_broadcast_tasks(id, tenant_id),
    FOREIGN KEY (device_id, tenant_id) REFERENCES ios_devices(id, tenant_id),
    UNIQUE (id, tenant_id)
);
CREATE INDEX IF NOT EXISTS idx_ios_items_dispatch
    ON ios_broadcast_task_items(device_id, not_before, ordinal)
    WHERE status IN ('pending','recovery_required');
CREATE INDEX IF NOT EXISTS idx_ios_items_lease_expiry
    ON ios_broadcast_task_items(lease_until)
    WHERE status IN ('leased','preparing','click_committed');
CREATE INDEX IF NOT EXISTS idx_ios_items_task_page
    ON ios_broadcast_task_items(task_id, ordinal, id);

CREATE TABLE IF NOT EXISTS ios_automation_events (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    device_id TEXT,
    task_id TEXT,
    item_id TEXT,
    event_type TEXT NOT NULL,
    actor_type TEXT NOT NULL CHECK (actor_type IN ('user','ios_agent','ios_controller','system')),
    actor_id TEXT NOT NULL,
    error_code TEXT NOT NULL DEFAULT '',
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (device_id, tenant_id) REFERENCES ios_devices(id, tenant_id),
    FOREIGN KEY (task_id, tenant_id) REFERENCES ios_broadcast_tasks(id, tenant_id),
    FOREIGN KEY (item_id, tenant_id) REFERENCES ios_broadcast_task_items(id, tenant_id)
);
CREATE INDEX IF NOT EXISTS idx_ios_events_tenant_time
    ON ios_automation_events(tenant_id, occurred_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_ios_events_item_time
    ON ios_automation_events(item_id, occurred_at, id)
    WHERE item_id IS NOT NULL;
```

`error_detail` 最多 500 字符且必须脱敏；`metadata` 禁止存 phone、content、token、secret、完整 source 或截图。

### 10.1 状态计数事务

每次 item 状态变化都在同一事务中，所有入口都接收并校验 `tenantID + taskID + itemID`。为让 kill switch 提交与 lease/phase 有确定的先后关系，所有会影响领取或 click 边界的事务锁顺序固定为 **global switch row -> tenant switch row -> device -> item -> task**：

1. `INSERT ... ON CONFLICT DO NOTHING` 确保全局和当前 tenant 的 switch row 存在。
2. 按 `tenant_id=''` 再 `tenant_id=$tenantID` 执行 `SELECT key,value FROM system_config ... FOR UPDATE`；持锁后重新读取值。kill switch `PUT` 也必须先锁同两行（全局接口只需全局行），因此 phase 不可能在已提交开关之后使用旧的 false 快照。
3. `SELECT d.id FROM ios_devices d JOIN ios_broadcast_task_items i ON i.device_id=d.id AND i.tenant_id=d.tenant_id WHERE d.tenant_id=$tenantID AND i.task_id=$taskID AND i.id=$itemID FOR UPDATE OF d`；不存在即返回资源不存在，不泄露跨租户资源。
4. `SELECT ... FROM ios_broadcast_task_items WHERE tenant_id=$tenantID AND task_id=$taskID AND id=$itemID FOR UPDATE`，校验允许的旧状态、controller/lease owner、lease token 和 click 边界。
5. `SELECT ... FROM ios_broadcast_tasks WHERE tenant_id=$tenantID AND id=$taskID FOR UPDATE`。
6. 更新 item；对该 task 最多 100 行重新 `COUNT(*) FILTER (WHERE status=...)`；更新五个 counter 和 task status。
7. 插入 `ios_automation_events`，commit 后发布浏览器 WS 事件。

任何其他会影响 click 边界的路径（领取、续租、phase、kill switch、恢复）也必须按 global switch -> tenant switch -> device -> item -> task 的相对顺序锁定其实际涉及的行；这不要求 kill switch PUT 去锁无关 device/item。reaper、禁用和撤销至少遵守 device -> item -> task。进程内 mutex 只优化等待，不能作为正确性保证。增加真实 PostgreSQL barrier 测试：kill switch 提交成功后，并发 phase 必须返回 `IOS_AUTOMATION_KILL_SWITCH`，不得写 `send_clicked_at`。

任务结束规则：无非终态 item 时，若 `cancel_requested_at IS NOT NULL` 则为 `canceled`（可能已有部分 sent，计数如实保留）；否则全部 sent -> `completed`；存在 failed/unknown/canceled -> `completed_with_errors`。

`pending_count` 是全部非终态且尚未 sent/failed/unknown/canceled 的数量，包含 pending、leased、preparing、click_committed 和 recovery_required；五个 counter 之和必须始终等于 `total_count`。数据库测试必须在每一种状态转换后断言该不变量。

`sendClickCommitted` phase 的同一事务使用 `crypto/rand` 在 task 的 `[min_delay_ms,max_delay_ms]` 闭区间生成均匀毫秒数，并把 `ios_devices.next_send_not_before` 设置为 `GREATEST(当前值, now() + delay)`。该推进发生在真正 click 之前，属于防重复/限频的保守边界；即使 controller 随后崩溃，同设备也不能立即领取下一项。间隔只用于频率上限，不用于伪装真人行为。

`ios_automation_events.event_type` 的 v1 常量只能取：`device_created`、`enrollment_code_issued`、`agent_enrolled`、`agent_token_rotated`、`vpn_status_changed`、`wda_probe_completed`、`device_recovery_required`、`device_recovered`、`device_disabled`、`device_retired`、`device_revoke_requested`、`device_revoke_completed`、`kill_switch_changed`、`task_created`、`task_paused`、`task_resumed`、`task_cancel_requested`、`item_leased`、`item_preparing`、`send_click_committed`、`item_sent`、`item_failed`、`item_unknown`、`item_recovery_required`、`item_sensitive_inspected`、`item_manual_resolved`、`task_completed`。在 `internal/model/ios_automation.go` 定义常量并由 store 拒绝其他值；不把任意外部字符串直接写入审计表。

## 11. 后端文件、RBAC 和 API

### 11.1 后端文件

```text
internal/model/ios_automation.go
internal/store/ios_migrations.go
internal/store/ios_devices.go
internal/store/ios_broadcasts.go
internal/store/ios_leases.go
internal/store/ios_automation_test.go
internal/middleware/ios_agent_auth.go
internal/middleware/ios_controller_auth.go
internal/handler/ios_devices.go
internal/handler/ios_broadcasts.go
internal/handler/ios_agent.go
internal/handler/ios_controller.go
internal/handler/ios_*_test.go
cmd/server/main.go
internal/handler/ws.go
internal/handler/ws_test.go
.env.example
deploy.sh                              # 构建/备份/启停 server、connector、ios-controller
deploy/systemd/whatsapp-ai-ios-controller.service
scripts/verify-easytier-release.sh     # 固定 binary digest 和 canary 日志门禁
```

server 新增 `IOS_CONTROLLER_URL`，生产默认不提供隐式值；同机部署明确配置为 `http://127.0.0.1:8792`。该 URL 只从环境读取，管理员请求体和数据库均不能覆盖。server 启动时要求 URL 为 HTTPS 或 loopback HTTP。

server 到 controller 使用禁代理、禁重定向的专用 client；revoke 总超时 5 秒，probe 总超时 45 秒，响应 body 上限 1 MiB。超时只形成持久 revoke pending 或 probe failed，不能被当作成功。

server 还必须配置 `IOS_EASYTIER_PUBLIC_HOST`，值只能是规范化 DNS hostname，不能带 scheme、path 或 port；创建设备和 agent config 都从该环境变量读取 relay host。缺失或非法时禁止创建设备，不得回退到请求 Host header。

现有 `.env.example` 和生产 `/etc/whatsapp-ai.env` 必须新增并校验：`IOS_CONTROLLER_URL`（同机为 `http://127.0.0.1:8792`）、`IOS_CONTROLLER_TOKEN`（至少 32 随机字节，与 controller env 相同）、`IOS_EASYTIER_PUBLIC_HOST`（仅 DNS hostname）和 `IOS_AUTOMATION_GLOBAL_KILL_SWITCH`（默认 `true`，仅作为首次启动保护；数据库全局 switch 是运行时权威）。controller 使用独立 `/etc/whatsapp-ios-controller.env`，包含 `IOS_CONTROLLER_ID`、`IOS_PLATFORM_URL`、`IOS_CONTROLLER_TOKEN`、`IOS_EASYTIER_BIN`、`IOS_EASYTIER_STATE_DIR`、绝对 `IOS_WDA_SELECTORS`；两个 env 文件权限均为 `0600`，不得把 token 写入仓库。

所有 JSON 字段使用现有 camelCase；时间响应使用 RFC3339 UTC 字符串；数据库使用 `TIMESTAMPTZ`。

### 11.2 RBAC 菜单

在 `internal/store/rbac.go` 的 `seedMenuRows` 增加：

| ID | 父级 | 类型 | 名称 | code | path/icon |
|---|---|---|---|---|---|
| `m-ios-devices` | `dir-ops` | menu | iOS 设备 | `ios_devices:view` | `ios-devices` / `Smartphone` |
| `b-ios-devices-create` | `m-ios-devices` | button | 新建设备 | `ios_devices:create` | 空 |
| `b-ios-devices-update` | `m-ios-devices` | button | 配置/探活/恢复设备 | `ios_devices:update` | 空 |
| `b-ios-devices-delete` | `m-ios-devices` | button | 禁用设备 | `ios_devices:delete` | 空 |
| `b-ios-devices-retire` | `m-ios-devices` | button | 撤销并重建设备 | `ios_devices:retire` | 空 |
| `m-ios-broadcasts` | `dir-ops` | menu | iOS 群发 | `ios_broadcasts:view` | `ios-broadcasts` / `Send` |
| `b-ios-broadcasts-create` | `m-ios-broadcasts` | button | 创建群发 | `ios_broadcasts:create` | 空 |
| `b-ios-broadcasts-update` | `m-ios-broadcasts` | button | 暂停/恢复/取消 | `ios_broadcasts:update` | 空 |
| `b-ios-broadcasts-resolve` | `m-ios-broadcasts` | button | 人工处理未知结果 | `ios_broadcasts:resolve` | 空 |
| `b-ios-broadcasts-inspect` | `m-ios-broadcasts` | button | 查看未知项核对信息 | `ios_broadcasts:inspect_sensitive` | 空 |
| `b-ios-broadcasts-kill-switch` | `m-ios-broadcasts` | button | 群发全局/租户熔断 | `ios_broadcasts:kill_switch` | 空 |

存量租户 top-up：两个 menu 和九个 button 加入 `tenant_menus`；admin preset 加全部；agent/viewer preset 只加两个 menu。`ios_broadcasts:kill_switch` 的全局操作另受 `RequirePlatformAdmin` 保护。owner 动态继承 ceiling。不得覆盖租户已有的其他裁剪。

### 11.3 管理 API

所有路由位于现有 `api := router.Group('/api', Auth, RequireCSRF)` 下，并叠加 active tenant 和对应权限。

| 方法 | 路径 | 权限 | 成功 |
|---|---|---|---|
| `GET` | `/api/ios-devices?cursor=&limit=50` | `ios_devices:view` | 200 cursor page |
| `POST` | `/api/ios-devices/enrollment-code` | `ios_devices:create` | 201 租户注册码（App 注册自动建设备） |
| `PATCH` | `/api/ios-devices/:id` | `ios_devices:update` | 200 补录 udid/name/whatsappVersion |
| `GET` | `/api/ios-devices/:id` | `ios_devices:view` | 200 |
| `PATCH` | `/api/ios-devices/:id` | `ios_devices:update` | 200；只更新允许的展示/selector 字段 |
| `POST` | `/api/ios-devices/:id/enrollment-code` | `ios_devices:update` | 201 新 code，旧未用 code 失效 |
| `POST` | `/api/ios-devices/:id/probe` | `ios_devices:update` | 200 四阶段探活结果 |
| `POST` | `/api/ios-devices/:id/recover` | `ios_devices:update` | 200；完整 probe 通过才允许 |
| `DELETE` | `/api/ios-devices/:id` | `ios_devices:delete` | controller 同步确认时 200，否则 202；实际置 disabled，不硬删审计 |
| `POST` | `/api/ios-devices/:id/retire` | `ios_devices:retire` | controller 同步确认时 200，否则 202；永久撤销旧网络并要求重新建档 |
| `PUT` | `/api/ios-automation/kill-switch` | `ios_broadcasts:kill_switch` | 200；当前租户熔断 |
| `PUT` | `/api/platform/ios-automation/kill-switch` | platform admin + `ios_broadcasts:kill_switch` | 200；全局熔断 |
| `GET` | `/api/ios-broadcasts?cursor=&limit=50` | `ios_broadcasts:view` | 200 |
| `POST` | `/api/ios-broadcasts` | `ios_broadcasts:create` | 201；重复幂等请求 200 |
| `GET` | `/api/ios-broadcasts/:id` | `ios_broadcasts:view` | 200 task + counters |
| `GET` | `/api/ios-broadcasts/:id/items?cursor=&limit=100` | `ios_broadcasts:view` | 200 |
| `POST` | `/api/ios-broadcasts/:id/pause` | `ios_broadcasts:update` | 200 |
| `POST` | `/api/ios-broadcasts/:id/resume` | `ios_broadcasts:update` | 200 |
| `POST` | `/api/ios-broadcasts/:id/cancel` | `ios_broadcasts:update` | 202 |
| `POST` | `/api/ios-broadcasts/:id/items/:itemId/retry` | `ios_broadcasts:update` | 200；仅未 click 的 failed/recovery |
| `POST` | `/api/ios-broadcasts/:id/items/:itemId/resolve` | `ios_broadcasts:resolve` | 200；unknown 人工确认 |
| `POST` | `/api/ios-broadcasts/:id/items/:itemId/inspection` | `ios_broadcasts:inspect_sensitive` | 200；60 秒不缓存的核对数据，并写审计 |

`PATCH /api/ios-devices/:id` body 只允许 `name`、`whatsappVersion`、`locale`，至少出现一项；禁止修改 tenant、UDID、vpn_ip、network name/secret、controllerId、status 或 enabled。`name` trim 后为 1..100 个 Unicode code point；`whatsappVersion` 为 1..32 个 ASCII 数字/点；`locale` 只能取已通过 M0 的 profile locale。创建设备时 `controllerId` 必须在 server 配置的 allowlist 中，不能因为请求传入任意值就被接受。

创建设备请求：

```json
{
  "name": "US iPhone 01",
  "udid": "value-captured-by-xcode",
  "controllerId": "us-1",
  "whatsappVersion": "2.26.15.1",
  "locale": "zh_CN"
}
```

创建设备时管理员同时录入当前 WhatsApp version 和 locale；App 无权读取其他 App 的版本。生产 iPhone 必须关闭 App Store 自动更新。controller 按数据库记录选择 selector profile，并以 M0 固化的 UI 结构 fingerprint 再校验；记录版本与 fingerprint 不匹配时返回 `WHATSAPP_VERSION_UNSUPPORTED`，不能继续点击。

`POST /api/ios-devices/:id/enrollment-code` 必须先锁 device 行并使该设备其他未消费 code 失效。online/offline/pending_enrollment 设备可签发新 code，但签发本身不改变当前 token；只有新 code 成功消费时才替换 token。disabled 设备仅在 `revoke_required=false` 时可签发，retired 设备永远返回冲突。明文 code 只在本次 201 响应出现并设置 `Cache-Control: no-store`。

创建群发请求必须带 `Idempotency-Key` header；值为 16..128 个 ASCII 字符且只允许 `[A-Za-z0-9._:-]`，超长或非法值在读取 request body 前返回 400：

```json
{
  "deviceIds": ["device-id-1", "device-id-2"],
  "recipients": ["+8613800000000", "+14155550123"],
  "content": "经授权的测试消息",
  "scheduledAt": "2026-08-06T12:00:00Z",
  "pacing": {"minDelayMs": 8000, "maxDelayMs": 15000}
}
```

校验必须原子完成：1..20 台 online 设备、1..100 个收件人、每个号码经现有 `phonenumbers` 规范化为唯一 E.164、正文 trim 后 1..4000 UTF-8 字节、delay 合法、scheduledAt 不超过未来 30 天。任一号码无效或规范化后重复，返回 `422 INVALID_RECIPIENTS` 和逐项 index/code，不创建任务。

分配按输入 `deviceIds` 顺序轮询，跳过 disabled/recovery 设备；每设备保持原 recipients 相对顺序。request hash 是规范化 JSON 的 SHA-256。相同 tenant + idempotency key + 相同 hash 返回原任务；hash 不同返回 `409 IDEMPOTENCY_CONFLICT`。

`inspection` 仅允许对当前租户的 unknown item 调用，并使用固定原因码，禁止把自由文本、号码或正文写进审计：

```json
{"reasonCode":"unknown_outcome_review"}
```

响应必须设置 `Cache-Control: no-store`，只返回一次性内存数据和 `expiresAt = now + 60s`：

```json
{"recipientE164":"+14155550123","content":"经授权的测试消息","expiresAt":"2026-08-06T12:01:00Z","inspectionEventId":"event-id"}
```

服务端不保存响应正文；前端在 60 秒后清空显示。每次 inspection 都限速并写 `item_sensitive_inspected`，metadata 只存 actor、task/item 和 `reasonCode`，不存号码或正文。

`resolve` body 只允许以下形式，并必须带最近 5 分钟内、同一用户/租户/item 的 `inspectionEventId`：

```json
{"resolution":"confirmSent","reasonCode":"visible_outgoing_bubble","inspectionEventId":"event-id"}
```

或：

```json
{"resolution":"confirmNotSent","reasonCode":"confirmed_absent_after_review","inspectionEventId":"event-id"}
```

resolution 与 reasonCode 必须严格配对：`confirmSent` 只接受 `visible_outgoing_bubble`，`confirmNotSent` 只接受 `confirmed_absent_after_review`。`confirmSent` 把 item 置 sent 并标 `manual_confirm_sent`；`confirmNotSent` 只有当前 unknown 且带有效 inspection 时可清除 lease、置 pending、标 `manual_confirm_not_sent`，随后才可能再次发送。两者都必须写用户 ID 和审计 reasonCode；没有 `ios_broadcasts:inspect_sensitive` 的用户不能执行任一 resolve。这样操作员不会仅凭脱敏号码触发重发。

`confirmNotSent` 的同一事务还必须清空 `send_clicked_at`、`verified_at`、baseline/post-click hash、error、lease 字段，把 `attempt_count` 重置为 `0` 并设置 `not_before = now() + interval '5 seconds'`；普通 failed/recovery 的显式 retry 同样把 `attempt_count` 重置为 `0`。历史尝试次数保留在 `ios_automation_events`，不靠当前行累计。若 task `cancel_requested_at IS NOT NULL` 或状态为 `canceled`，两种操作都拒绝；否则事务清空 `finished_at` 并将 task 重开为 `queued`，paused task 保持 `paused`，由后续 resume 才能领取。

disable/retire 响应 body 固定为 `{"deviceId":"...","status":"disabled|retired","revokePending":true|false,"revokeGeneration":N}`。若 controller 在 handler 超时内回显当前 generation 并完成清理，server 在同一代确认事务后返回 200 和 `revokePending=false`；否则持久化待办后返回 202 和 `revokePending=true`。不得返回 204 后让前端猜测撤销是否完成。

### 11.3.1 Kill switch 与设备撤销控制面

复用已核验的复合主键 `system_config(tenant_id,key)` 保存两个布尔控制项。migration 只在 key 不存在时写入初始值；之后环境变量不能覆盖数据库值：

| scope | `tenant_id` | key | 默认值 |
|---|---|---|---|
| 全局 | `''` | `ios_automation.global_kill_switch` | `true`（首次迁移安全默认） |
| 租户 | 当前 tenant | `ios_automation.tenant_kill_switch` | `false` |

`PUT` 接口只接受 `{"enabled":true|false,"reasonCode":"..."}`。开启只允许 `operator_stop|account_warning|incident|maintenance`，关闭只允许 `resume_after_review`；拒绝自由文本。在同一事务按 global switch -> tenant switch 顺序锁行、更新配置并写 `kill_switch_changed`；全局事件使用 `tenant_id=''` 且不绑定资源。租约领取和 `sendClickCommitted` phase 都先锁同两行并在持锁后读取值，任一为 true 即返回 `IOS_AUTOMATION_KILL_SWITCH`；已越过 click 边界的 item 只允许完成验证或落 `unknown`，不强杀点击中的请求。关闭开关后不自动重开已失败/unknown 项。

设备 `DELETE` 是可恢复的 disabled。事务按 device -> item id -> task id 顺序锁定，立即置 `enabled=false/status=disabled`、清除 agent token hash、拒绝新 lease，并设置 `revoke_required=true`、`revoke_generation=revoke_generation+1`、`revoke_attempt_count=0`、`revoke_next_attempt_at=now()`。该设备所有尚未 click 的 `leased|preparing` item 转 `recovery_required` 并清 lease；pending 保留以便设备重新 enrollment 后继续。已经 `click_committed` 的 item 保留 lease，result endpoint 即使设备 disabled 也只允许其落 sent/unknown；revoke handler/reconciler 必须等该设备没有 `click_committed`，或其 lease 过期被 reaper 置 unknown 后，才能停止 EasyTier。这样禁用立即阻止新点击，但不会主动切断一次已经发生的点击验证。

若要处理疑似 network secret 泄漏，必须使用 `retire`，安全撤销优先于等待验证。事务同样按 device -> item id -> task id 锁定，置 `status=retired/enabled=false/revoke_required=true`、递增 generation、设置 `retired_at`，清除 installation/token hash；该设备所有 pending/leased/preparing item 转 `failed` 并记 `IOS_DEVICE_RETIRED_BEFORE_CLICK`，所有 click_committed item 转 `unknown` 并记 `IOS_DEVICE_RETIRED_AFTER_CLICK`，清理 lease 并重算涉及 task 的计数。随后把该设备 `vpn_ip` 标记为永久不可复用（`retired` 状态下 IP 分配路径拒绝复用），并确保 ACL 已移除该设备；任何解密路径都拒绝 retired 状态。事务写 `device_retired`、`device_revoke_requested` 和逐 item 事件后立即请求 controller revoke。

server 通过 `IOS_CONTROLLER_URL` 调用 loopback `POST /v1/devices/{id}/revoke`；controller 按 device id + generation 幂等停止 EasyTier、删除配置文件并回显 generation。server 的 revoke reconciler 使用专用 PostgreSQL 连接持有 `pg_try_advisory_lock(hashtext('ios-revoke-reconciler-v1'))`；未取得锁的实例不运行扫描，连接丢失立即停止本轮。leader 每 5 秒扫描 `status IN ('disabled','retired') AND revoke_required=true AND (revoke_next_attempt_at IS NULL OR revoke_next_attempt_at<=now())`。每个设备先用短事务锁 device、检查 disabled 设备已无 click_committed、递增 attempt 并设置指数退避（5s、10s、20s...上限 5min），提交后再调用 controller，禁止持数据库行锁等待网络。成功时新事务重新锁 device，只有数据库仍是同一 generation 才清 `revoke_required` 并写 `device_revoke_completed`；失败只记录脱敏 `revoke_last_error` 并保留待办。

controller 离线、server 重启和重复 revoke 都必须由 generation + 持久待办恢复。disabled 设备只有 revoke 完成后才能由管理员签发新 enrollment code；新 code 成功消费后 server 重新启用并转 `vpn_connecting`，controller reconcile 配置，完整 probe 通过后管理员调用 recover 将 pre-click recovery items 重开。retired 永远不能 re-enable；管理员必须创建新 device ID、slot、network secret 和 enrollment code，物理 iPhone 重新 enrollment。这样不实现高风险的原地双密钥切换。

### 11.4 Controller internal API

独立 middleware 读取 `IOS_CONTROLLER_TOKEN`，常量时间比较；不创建 platform admin synthetic session。

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/api/internal/ios-controller/v1/devices?controllerId=us-1` | 返回该 controller 的启用设备（含 vpn_ip）及单一网络配置引用（5.3） |
| `POST` | `/api/internal/ios-controller/v1/devices/:id/status` | EasyTier/WDA probe 状态 |
| `POST` | `/api/internal/ios-controller/v1/devices/:id/lease` | 为已 reconcile 的指定 device 领取一个安全可执行 item；无任务返回 204 |
| `POST` | `/api/internal/ios-controller/v1/items/:id/phase` | `preparing` 或 `sendClickCommitted` |
| `POST` | `/api/internal/ios-controller/v1/items/:id/lease/renew` | 显式续租，不能由 phase/result 隐式续租 |
| `POST` | `/api/internal/ios-controller/v1/items/:id/result` | sent/failed/unknown/recoveryRequired |

所有 internal 请求除 Bearer 外必须带 `X-IOS-Controller-ID`；server 将其作为 lease owner 身份的一部分校验，不能由请求体覆盖。`GET /devices` 的 `controllerId` query 必须与 header 完全相等，否则返回 403。lease 响应包含 `taskId`、`itemId`、`deviceId`、lease token 和必要正文/号码，controller 不缓存到磁盘；phase、renew、result 请求都必须回传 `taskId` 和 `leaseToken`，server 用 `tenant_id + task_id + item_id` 复合谓词再次校验。初始 lease 90 秒，`lease_started_at` 写入领取时间；controller 每 30 秒调用 renew。renew 请求为 `{"taskId":"...","leaseToken":"..."}`，只接受 `leased|preparing|click_committed`、未过期、token/owner/device/controller 全部匹配的 item，原子地把 `lease_until` 延长到 `LEAST(now()+90s, lease_started_at+10min)`，返回新的 RFC3339 `leaseUntil`。过期、token 不匹配或已终态返回 409；kill switch/设备禁用对 leased、preparing 返回 409，但 click_committed 仍可在 10 分钟总上限内续租并提交 sent/unknown，保证已经发生的点击可以收尾。phase/result 不得代替 renew；响应丢失时可用同一 token 重试，stale worker 永远不能续租。reaper 与 renew 通过同一 device -> item 锁顺序竞态测试。

管理端同步 probe 不经过这些 server internal 路由：server 先完成 tenant/RBAC/device 归属校验，再使用环境中的 loopback controller URL 调用 `POST /v1/devices/{id}/probe`。controller 返回的 network secret、原始 source 和 screenshot 永远不进入该响应。

### 11.5 浏览器 WS 扩展

在现有 `WSEvent`/`canReceive` 增加：

| event type | 权限 | payload |
|---|---|---|
| `ios_device_status` | `ios_devices:view` | deviceId/status/timestamps/errorCode，无 IP/secret |
| `ios_broadcast_progress` | `ios_broadcasts:view` | taskId/counters/status/updatedAt |
| `ios_broadcast_item` | `ios_broadcasts:view` | taskId/itemId/status/errorCode，不含 phone/content |

浏览器断线重连后重新 GET 当前 task/device，不能依赖 WS 重放。

## 12. 租约、幂等和状态机

### 12.1 Item 状态机

```text
pending -> leased -> preparing -> click_committed -> sent
   |         |          |               `-------> unknown
   |         |          `-> failed/recovery_required
   |         `-> pending（lease 过期且未 click）
   `-> canceled

failed/recovery_required -> pending（显式 retry/recover，且从未 click）
unknown -> sent（人工 confirmSent）
unknown -> pending（人工 confirmNotSent）
```

禁止转换：`sent -> *`、自动 `unknown -> pending`、`click_committed -> pending`、`canceled -> pending`。人工 `confirmNotSent` 是显式、有权限、有 inspection 证据的重开，不属于自动转换。

人工 retry/confirmNotSent 与 task 状态在同一事务处理：`cancel_requested_at IS NOT NULL` 或 `canceled` 永远拒绝；`paused` 保持 paused；其余可重试 task 清 `finished_at` 并置 `queued`，使 scheduler 能再次领取。随后每次状态重算遵循 `cancel > terminal > paused > active/queued`：取消请求先处理 pending；无非终态 item 才落 completed/completed_with_errors/canceled；暂停不被 item 计数覆盖；其余有 active lease 时为 running，否则为 queued。这样终态 task 不会留下 pending item 却仍不可领取的状态。

### 12.2 Lease 查询

controller 只可为 `GET /devices` 已返回、且自身 `X-IOS-Controller-ID` 匹配的一个 device 调用 `POST /devices/:id/lease`。server 先只读取得该 device 的 tenant 锁键，随后在一个 PostgreSQL 事务中按 **global switch row -> tenant switch row -> device -> item -> task** 锁定并重新校验；不能先锁两个候选 item 再检查设备。伪 SQL：

```sql
-- Read only: obtain tenant lock key; every device predicate is rechecked below.
SELECT tenant_id FROM ios_devices WHERE id=$deviceID;
BEGIN;
INSERT INTO system_config(tenant_id,key,value,description)
VALUES ('','ios_automation.global_kill_switch','true','initial iOS automation safety switch')
ON CONFLICT (tenant_id,key) DO NOTHING;
INSERT INTO system_config(tenant_id,key,value,description)
VALUES ($tenantID,'ios_automation.tenant_kill_switch','false','tenant iOS automation safety switch')
ON CONFLICT (tenant_id,key) DO NOTHING;
SELECT key,value FROM system_config
 WHERE (tenant_id='' AND key='ios_automation.global_kill_switch')
    OR (tenant_id=$tenantID AND key='ios_automation.tenant_kill_switch')
 ORDER BY tenant_id
 FOR UPDATE;
-- Reject immediately if either locked row is true.
SELECT d.id
  FROM ios_devices d
 WHERE d.id = $deviceID
   AND d.tenant_id = $tenantID
   AND d.controller_id = $controllerID
   AND d.enabled = true
   AND d.status IN ('online','busy')
   AND d.next_send_not_before <= now()
 AND EXISTS (SELECT 1 FROM ios_broadcast_task_items i
                JOIN ios_broadcast_tasks b ON b.id=i.task_id AND b.tenant_id=i.tenant_id
               WHERE i.device_id=d.id AND i.tenant_id=d.tenant_id
                 AND i.status='pending' AND i.not_before <= now()
                 AND b.status IN ('queued','running')
                 AND b.cancel_requested_at IS NULL AND b.scheduled_at <= now())
 FOR UPDATE OF d SKIP LOCKED;
SELECT i.id,i.task_id
  FROM ios_broadcast_task_items i
  JOIN ios_broadcast_tasks b ON b.id=i.task_id AND b.tenant_id=i.tenant_id
 WHERE i.device_id=$deviceID AND i.tenant_id=$tenantID
   AND i.status='pending' AND i.not_before<=now() AND i.attempt_count<3
   AND b.status IN ('queued','running') AND b.cancel_requested_at IS NULL
   AND b.scheduled_at<=now()
   AND NOT EXISTS (SELECT 1 FROM ios_broadcast_task_items active
                    WHERE active.device_id=$deviceID AND active.tenant_id=$tenantID
                      AND active.status IN ('leased','preparing','click_committed')
                      AND active.lease_until>now())
 ORDER BY i.ordinal
 LIMIT 1
 FOR UPDATE OF i;
-- Bind the single returned row to $itemID and $taskID; no row means ROLLBACK + HTTP 204.
SELECT id FROM ios_broadcast_tasks
 WHERE id=$taskID AND tenant_id=$tenantID
 FOR UPDATE;
-- Re-check all predicates after every lock is held, then update item/task.
COMMIT;
```

item 查询必须最多返回一行，应用只能从该锁定行取得 `$itemID/$taskID`，不能使用请求参数或锁定前的候选值。没有 item 时释放事务并返回 204。在设备、该 item 和其 task 行全部锁住后同时满足：

- task 为 queued/running，未暂停/取消，scheduledAt 已到；
- item pending，notBefore 已到；
- device enabled、online，controllerId 匹配；
- `device.next_send_not_before <= now()`；
- 同 device 不存在 lease 未过期的 leased/preparing/click_committed item（锁后再次检查）；
- attemptCount < 3。

领取后：item -> leased、`attempt_count + 1`、生成 32 字节 lease token、`lease_started_at = now()`、`lease_until = now()+90s`；task queued -> running。`system_config` 开关在领取事务和 phase 事务均锁行后重新检查；开关竞态以先取得 switch row lock 的事务为准，开关已提交后开始的 phase 不得跨越 click 边界。

### 12.3 Lease reaper

每 15 秒，先按 device_id 排序锁设备行，再锁对应 item/task；不能只扫描 item：

- lease 过期且 `send_clicked_at IS NULL`：置 pending，清 lease，notBefore = now + 5s；
- lease 过期且 `send_clicked_at IS NOT NULL`：置 unknown，错误 `LEASE_EXPIRED_AFTER_CLICK`；
- task cancel requested：所有 pending 直接 canceled；leased/preparing 在下一 phase 前返回 canceled；click_committed 不强杀，等待 sent/unknown。

reaper 清 lease 时同时清空 `lease_started_at`、`lease_owner`、`lease_token`、`lease_until`。renew 与 reaper 同时命中时只有持有 device -> item 锁的事务能成功；另一方重新读取状态后返回 409 或执行唯一一次回收。

### 12.4 设备恢复

设备 `recovery_required` 后不再 lease。完整 probe 成功只说明技术条件恢复；管理员调用 recover 后：

- 从未 click 的 `recovery_required` items 置 pending；
- unknown 保持不变；
- 对因此重新出现 pending item 的非 canceled task 清 `finished_at` 并按第 12.1 节重开为 queued（paused task 保持 paused）；
- 设备置 online；
- 记录 `device_recovered` 审计。

## 13. 前端详细设计

### 13.1 文件

```text
frontend/src/views/IOSDevicesView.vue
frontend/src/views/IOSBroadcastsView.vue
frontend/src/components/IOSEnrollmentDialog.vue
frontend/src/components/IOSDeviceProbeDialog.vue
frontend/src/components/IOSBroadcastCreateDialog.vue
frontend/src/components/IOSBroadcastItemsDialog.vue
frontend/src/api/index.js
frontend/src/views/Dashboard.vue
frontend/src/api.test.js
frontend/src/views/IOSDevicesView.test.js
frontend/src/views/IOSBroadcastsView.test.js
```

### 13.2 iOS 设备页

表格列：设备名、状态、iOS/WhatsApp/WDA 版本、App channel、VPN 最近可达、WDA 最近可达、最近错误、操作。IP、UDID 只在详情中脱敏展示；secret/token 永不展示。

操作按权限显示：新建设备、重新生成 enrollment code、探活、恢复、禁用。Enrollment code 只显示一次，关闭后不再从 API 获取原值。

Probe 弹窗固定四行：EasyTier process、VPN route、WDA status/session、source/screenshot。任何一行失败整体不通过。

### 13.3 iOS 群发页

第一屏是任务表，不做营销页。顶部命令按钮“新建群发”；表格展示创建时间、设备数、总数、sent/failed/unknown/pending、状态、操作。

创建对话框包含：多选 online 设备、号码文本区、正文、计划时间、最小/最大间隔。提交前本地校验仅为体验，服务端校验为权威。提交按钮在请求中禁用，生成随机 Idempotency-Key 并在失败重试时复用。

任务详情逐项展示号码脱敏值、设备、状态、attempt、errorCode、时间。unknown 的固定操作状态机为：

1. 先点“核对”并用固定 `unknown_outcome_review` 原因码调用 inspection；无 `ios_broadcasts:inspect_sensitive` 时只显示权限错误，不能显示 resolve 按钮。
2. 成功后在不缓存的局部弹窗显示完整号码和任务正文 60 秒，保存 `inspectionEventId`；倒计时结束、弹窗关闭、接口失败或切换 item 时立即清空正文、号码和 event ID。
3. 仅在 event ID 未过期时显示“确认已发送/确认未发送”；二次确认按按钮映射固定 reasonCode，resolve 请求携带 event ID。服务端返回 inspection 过期/不匹配时关闭弹窗，要求重新核对。

浏览器内存、路由 query、localStorage、WS payload 均不得保存 inspection 内容或 event ID。

WebSocket 更新只修改对应 task counter；收到 `ws_reconnected` 后重新 GET 当前页和已打开详情。

### 13.4 现有群发隔离

不要修改 `BroadcastWorkbench` 的传输语义，也不要重新显示当前 Accounts 页隐藏的旧群发按钮。iOS 群发只从 `ios-broadcasts` 菜单进入，API 只调用 `/api/ios-broadcasts`。

## 14. 错误码

| errorCode | 阶段 | 是否自动重试 |
|---|---|---:|
| `IOS_ENROLLMENT_INVALID` | code 不存在/过期/已用或设备不可注册；对外不区分 | 否 |
| `IOS_AGENT_TOKEN_INVALID` | 设备 token | 否 |
| `IOS_DEVICE_DISABLED` | 设备禁用 | 否 |
| `IOS_DEVICE_RETIRED_BEFORE_CLICK` | 设备永久撤销，item 尚未 click | 否；新设备重新建任务 |
| `IOS_DEVICE_RETIRED_AFTER_CLICK` | 设备永久撤销，item 已 click | 禁止自动重试 |
| `IOS_DEVICE_ADDRESS_INVALID` | 虚拟 IP/slot 不一致 | 否 |
| `TUN_FD_UNAVAILABLE` | Packet Tunnel | 系统可重启隧道 1 次 |
| `EASYTIER_CONFIG_INVALID` | FFI parse | 否 |
| `EASYTIER_START_FAILED` | FFI/process | 退避后有限重试 |
| `EASYTIER_PEER_TIMEOUT` | 30 秒无 peer | 有限重试 |
| `WDA_UNREACHABLE` | `/status` | click 前有限重试 |
| `WDA_SESSION_INVALID` | session | click 前重建一次 |
| `WHATSAPP_VERSION_UNSUPPORTED` | selector profile | 否 |
| `WHATSAPP_RECIPIENT_INVALID` | UI 提示号码无效 | 否 |
| `WHATSAPP_COMPOSER_NOT_FOUND` | 输入框 | click 前有限重试 |
| `TEXT_INPUT_FAILED` | 正文校验失败 | click 前有限重试 |
| `SEND_BUTTON_NOT_FOUND` | 发送按钮 | click 前有限重试 |
| `SEND_OUTCOME_UNKNOWN` | click 后无法确认 | 禁止自动重试 |
| `LEASE_CONFLICT` | lease/phase token | controller 放弃 |
| `LEASE_EXPIRED_AFTER_CLICK` | click 后 worker 丢失 | 禁止自动重试 |
| `IOS_AUTOMATION_KILL_SWITCH` | 全局或租户开关已开启 | click 前停止；click 后只收尾 |
| `IDEMPOTENCY_CONFLICT` | 同 key 不同请求 | 否 |
| `INVALID_RECIPIENTS` | 批量号码校验 | 修正请求 |
| `TASK_NOT_CANCELABLE` | 终态任务 | 否 |

API 错误继续使用现有结构：

```json
{"error":{"code":"SEND_OUTCOME_UNKNOWN","message":"发送动作后无法确认结果，请人工核对。","requestId":"request-id"}}
```

## 15. 安全、隐私与合规

### 15.1 必须实现

- 管理 API：现有 session + CSRF + active tenant + RBAC。
- iOS Agent：独立 device token hash，不能复用浏览器 session 或 `INTERNAL_API_TOKEN`。
- Controller：独立 `IOS_CONTROLLER_TOKEN`，生产仅 HTTPS或 loopback。
- WDA：只通过共享 EasyTier 网络访问，且 ACL 只允许 controller 访问 `:8100`，禁止公网暴露与设备间互访（5.1）。
- SSRF：WDA host/port 从 slot 计算并严格验证，禁 proxy/redirect/DNS。
- Secret：AES-GCM at rest、Keychain、日志脱敏、配置文件 `0600`。
- 号码/正文：不进日志、指标、WS event、audit metadata；管理端按权限展示并默认脱敏。
- 截图/source：v1 只在 controller 进程内完成当次解析，原始内容不落盘、不上传、不进入 API、日志、审计或错误响应；M0 fixture 只保存人工脱敏版本及原始文件的 SHA-256。
- 设备禁用事务内立即让 token 失效、停止新 lease；pre-click item 转 recovery，click_committed item 完成 sent/unknown 或 lease 过期后，才通过 loopback revoke 控制面停止 EasyTier。控制器不可达时返回 `revokePending=true` 并持续重试，不能把尚未停止的网络宣称已撤销。
- 每任务最多 100 条、单设备串行、最小 5 秒间隔、支持平台 kill switch。

### 15.2 WhatsApp 风险

自动化官方 App 不等于获得 WhatsApp 批量营销授权。v1 不拥有 CRM consent/suppression 数据源，因此 opt-in、退订和抑制名单是租户运营前置条件，不写成平台已经验证的能力：运营方必须在提交前准备有可证明 opt-in 或现有业务关系的名单，并在外部名单中完成退订抑制。平台只实施号码规范化去重、每任务上限、设备级节流、人工暂停、kill switch 和审计；不会把任意 E.164 号码标成已合规，也不会伪造 consent 记录。

平台和运营必须同时：

- 监控账号警告、封禁、投诉并自动停机；
- 不设计规避风控、模拟随机手势、设备指纹伪造或验证码绕过。

最终验收不声称“系统证明 opt-in”，而是验证未提供合规名单时管理员仍能暂停/熔断，且请求、日志、审计不泄露正文和完整号码。

### 15.3 network secret 泄漏恢复

不实现原地双密钥切换。agent token 疑泄漏的设备走永久 `retire`：先失效 token、停止新 lease，再由 controller 从 ACL 移除该设备并确认其 `:8100` 不可达；server 保留旧审计。controller 或 server 任一步失败都保留 `revoke_required`，告警并每 5 秒重试。管理员随后创建新的 device ID、从 `10.168.0.0/16` 分配新虚拟 IP 和 10 分钟 enrollment code，现场重新 enrollment；旧设备记录不能 re-enable、旧 IP 永不复用。网络级 `network_secret` 疑泄漏时 ACL 仍阻止未授权访问 `8100`，但必须告警并按 5.2 全量重新 enroll（生成新 secret + 所有设备换新 code），不能仅 retire 单台。验收必须模拟 token/secret 出现在日志或配置备份后的撤销流程，证明旧虚拟 IP 不可达、旧 token 401、ACL 已移除该设备，并留下 `device_retired`、`device_revoke_requested`、`device_revoke_completed` 审计。

### 15.4 LGPL-3.0

EasyTier v2.6.4 为 LGPL-3.0。发布包必须包含：版权/许可证、所用固定源码和补丁、可重链接所需的静态库/对象或法律审查认可的等效交付方式。不得只在文档里放 GitHub 链接代替实际合规产物。WDA 按其 BSD-style LICENSE 一并归档。

## 16. 可观测性和告警

### 16.1 日志

统一字段：`component`、`request_id`、`controller_id`、`device_id`、`task_id`、`item_id`、`phase`、`status`、`error_code`、`duration_ms`。禁止 phone、content、token、secret、raw URL query、source、screenshot。

### 16.2 指标

避免 device/task/item 高基数 label：

- `ios_devices_total{status}`
- `ios_controller_leases_total{outcome}`
- `ios_controller_item_duration_seconds{outcome}`
- `ios_wda_probe_total{stage,outcome}`
- `ios_wda_probe_duration_seconds{stage}`
- `ios_easytier_processes{state}`
- `ios_broadcast_items_total{status,error_class}`
- `ios_agent_ws_connections{state}`

### 16.3 告警

- controller 2 分钟无 heartbeat；
- easytier-core 进程 5 分钟内重启 >= 5，或实例数与期望 enabled 设备数偏差 > 5%；
- online 设备连续 3 次 WDA probe 失败；
- 10 分钟窗口 unknown 比率 > 2%；
- 10 分钟窗口发送失败率 > 10%；
- enrollment/token 鉴权失败异常增长；
- controller 状态目录磁盘使用 > 80%。

## 17. 部署设计

### 17.1 美国服务器

仓库和现有 `deploy.sh` 的安装根目录统一为 `/opt/whatsapp_ai`，不得在新 unit 中使用 `/opt/whatsapp-ai`：

```text
/opt/whatsapp_ai/server
/opt/whatsapp_ai/connector
/opt/whatsapp_ai/ios-controller
/opt/whatsapp_ai/vendor/easytier/v2.6.4/easytier-core
/opt/whatsapp_ai/vendor/easytier/v2.6.4/easytier-core.sha256
/opt/whatsapp_ai/configs/ios-wda-selectors.json
/var/lib/whatsapp_ai/ios-networks/
```

`deploy.sh` 必须新增并校验以下步骤：构建 `.ios-controller.next`；验证 EasyTier binary SHA-256 与固定 v2.6.4 release manifest；将 selector fixture 复制到绝对路径；保留 `.ios-controller.previous` 和 EasyTier digest；迁移前停止 `whatsapp-ai-ios-controller.service`，迁移后按 server -> controller 顺序启动；失败时恢复两个旧二进制、旧 selector/digest 和服务状态。现有三表备份必须扩展为包含 `ios_devices`、`ios_device_enrollment_tokens`、`ios_broadcast_tasks`、`ios_broadcast_task_items`、`ios_automation_events`、`system_config`、新增 RBAC 表的 custom dump；表尚不存在时由脚本先用 `to_regclass` 过滤，不得因首次部署无表而误失败。恢复演练必须在隔离数据库执行 `pg_restore --list`、恢复后计数校验和新旧 server 启动验证。

提交 `deploy/systemd/whatsapp-ai-ios-controller.service`，内容必须完整如下（不能只列 capability）：

```ini
[Unit]
Description=WhatsApp AI iOS Controller
After=network-online.target whatsapp-ai.service
Wants=network-online.target
ConditionPathExists=/dev/net/tun

[Service]
Type=simple
User=whatsapp-ai
Group=whatsapp-ai
WorkingDirectory=/opt/whatsapp_ai
EnvironmentFile=/etc/whatsapp-ios-controller.env
ExecStartPre=/usr/bin/test -c /dev/net/tun
ExecStartPre=/opt/whatsapp_ai/ios-controller preflight --tun /dev/net/tun
ExecStart=/opt/whatsapp_ai/ios-controller
Restart=on-failure
RestartSec=5
TimeoutStopSec=45
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/whatsapp_ai/ios-networks
DevicePolicy=closed
DeviceAllow=/dev/net/tun rw
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
```

`preflight` 必须打开 `/dev/net/tun` 并完成最小 TUN ioctl 后立即关闭，不调用 `mknod`。部署前执行 `modprobe tun`、确认 `stat -c '%t:%T' /dev/net/tun` 和 `systemd-analyze verify /etc/systemd/system/whatsapp-ai-ios-controller.service`；任一失败不启动 controller。防火墙开放固定 `11010/11011` UDP/TCP 并限制新连接速率；只有服务端 easytier-core 监听这些端口。不开放 `8100`、EasyTier RPC 或数据库。

### 17.2 发布顺序

1. 数据库备份并执行新增表 SQL。
2. 发布 server：新 API 默认无设备，不影响现有 connector。
3. 发布 frontend：菜单由 RBAC 控制。
4. 安装 ios-controller、EasyTier 固定二进制、SHA-256 manifest 和 selector fixture；创建状态目录，完成 `/dev/net/tun` preflight 与 `systemd-analyze verify`，此时不启动 controller。
5. 启动 ios-controller，确认 `/health/ready`，kill switch 保持默认开启、不得领取任务。
6. 安装 v1 内部签名 iOS App（或已审核的 App Store 网络 Extension 构建），完成 M0；WDA 仍按第 8 章单独 USB 激活。
7. M0 全绿后关闭测试租户 kill switch，仅开放测试号码。
8. 小流量 1 设备/10 条，观察 24 小时。
9. 再按设备逐台启用。

### 17.3 回滚

- 先开启 kill switch，停止新 lease。
- 等待 click_committed 项进入 sent/unknown；不得直接杀进程制造重复。
- 停 `whatsapp-ai-ios-controller.service` 和 easytier-core（单进程，systemd），确认 `8100`/relay port 无监听。
- 若尚未关闭 kill switch、尚未安装新 schema 或尚未开放任何 iOS 任务流量，才允许按迁移失败流程恢复部署前 custom dump；恢复前必须确认没有新任务/lease，恢复后校验计数。
- 若已经有任务流量，**禁止恢复旧数据库快照**：只回滚 `.ios-controller.previous`、旧 EasyTier digest 和 selector fixture；数据库 schema、最新 task/item 状态、kill switch、revoke 状态和审计全部保留。旧 server 必须在发布前验证可读取新 schema，不能启动不兼容的旧二进制；不兼容时使用前向修复的新 server，而不是回放旧快照。
- 任何模式都执行 `systemd-analyze verify`、server/controller `/health/ready`、最新任务计数和一条只读 probe；数据库 dump 仅作为迁移前恢复材料，不是运行中回滚手段。
- 前端隐藏新菜单，server 可保留向后兼容只读 API。
- 新表为独立表，不删除；回滚不影响 accounts/whatsmeow 链路。
- iPhone 可在 App 内停止 VPN；不卸载 WDA/WhatsApp，不删除审计。

## 18. 测试设计

### 18.1 单元与契约

Go 必测：

- 共享网段 `10.168.0.0/16` 内设备虚拟 IP 唯一性与路由冲突；
- enrollment code 一次消费、过期、并发消费、响应丢失后用新 code 恢复；所有失败对外不可区分；disabled 必须等待 revoke 完成，retired 永远拒绝；
- token hash、禁用设备、tenant 隔离；
- API 幂等同请求重放和不同 hash 冲突；
- E.164 校验、规范化重复、100 条上限；
- 两个真实 pgx 连接、barrier 和 `READ COMMITTED` 下同设备不双 lease；测试必须按 switch -> device -> item -> task 锁顺序，不能用 mock SQL 代替；
- lease renew 成功、重复 renew、过期竞态、reaper/renew 并发和 10 分钟最大延长；kill switch/disabled 拒绝 pre-click renew，但允许 click_committed 收尾；
- lease expiry 在 click 前回 pending、click 后 unknown；
- 所有非法状态转换；终态 task 的 retry/confirmNotSent 清 `finished_at` 并重开 queued，cancel/paused 优先级正确；
- 合法 itemId + 错误 taskId/tenantId、controllerId/leaseOwner 不匹配全部拒绝；
- 全局/租户 kill switch 阻止新 lease 和 click phase，开关切换审计完整；
- disable 的 pre-click recovery、click_committed drain、revoke 完成后新 enrollment；retire 的 pre-click failed、post-click unknown、立即撤销、旧 slot 不复用；
- revoke leader advisory lock、持久 generation、controller 离线/重启/重复 revoke、网络调用期间不持有数据库行锁；
- SSRF：公网 IP、IPv6、不同 slot、非 8100、redirect、proxy 都拒绝；
- WDA envelope 正常/error/超大 body/timeout；
- click 只调用一次；selector 方向、正文、canonical identity 对重复正文、滚动、入站同文、人工同时触摸返回 sent 或 unknown；
- EasyTier CLI 和 FFI 启动日志 canary secret 扫描，stdout/stderr/device log 均不得出现 secret/config dump；
- source/screenshot 原始内容不写文件、数据库、API、日志或审计；
- 浏览器 WS tenant/permission 隔离。

Swift 必测：

- AgentConfig 对 CIDR/IP/port/host/configVersion 的严格校验；
- Keychain access group 可被 App 和 Extension 读取；
- config 原子写和损坏文件；
- EasyTier TOML escaping，任何字段不能注入新行/section；
- FFI error string 和 collect pair 全部释放；
- start/stop 重入、fd 只关闭一次；
- WSS 前后台状态和指数退避。
- Wi-Fi-only、蜂窝-only、承载切换不因 interfaceType 被拒绝；App Store build 禁止私有 KVC target。

前端必测：

- 权限隐藏/禁用命令；
- enrollment code 只显示一次；
- 创建请求复用同一 Idempotency-Key；
- invalid recipients 不提交；
- WS reconnect 后重新抓取；
- inspection -> 60 秒展示/清空 -> 带 event ID 的 unknown resolve、权限拒绝和过期重核对；

### 18.2 集成和故障注入

| 故障 | 注入点 | 期望 |
|---|---|---|
| EasyTier UDP 丢包 | 防火墙临时丢弃设备 port | TCP fallback 或 offline，不假在线 |
| 蜂窝切换/飞行模式 | iPhone | 120 秒内 VPN 恢复；任务 click 前可重试 |
| WDA 在 click 前退出 | 测试 Runner | recovery_required，可安全恢复 |
| WDA 在 click 后退出 | click mock/真机 | unknown，0 次自动重发 |
| Wi-Fi-only / Wi-Fi<->蜂窝 | iPhone 网络路径 | 120 秒内恢复同一虚拟 IP；不因 Wi-Fi 被拒绝 |
| server 在 phase commit 后重启 | 集成测试 | DB click 边界保留，reaper -> unknown |
| controller 在输入后崩溃 | SIGKILL | lease 过期 -> pending，因为未 click |
| controller 在 click 后崩溃 | SIGKILL | lease 过期 -> unknown |
| 浏览器 WS 中断 | Browser | 页面 fallback GET 一致 |
| token 泄漏模拟 | 轮换 token | 旧 token 立即 401/WSS 4001 |

### 18.3 验证命令

```bash
set -euo pipefail
: "${TEST_DATABASE_URL:?TEST_DATABASE_URL is required; use an isolated PostgreSQL 17 database}"
rtk go test ./...
rtk go test -race -count=1 ./internal/store ./internal/handler ./internal/ioscontroller/... -v | tee /tmp/ios-broadcast-go-test.log
if rtk rg -n -- "--- SKIP:|skipping PostgreSQL integration" /tmp/ios-broadcast-go-test.log; then
  echo "integration tests were skipped" >&2
  exit 1
fi
rtk pnpm --dir frontend test
rtk pnpm --dir frontend lint
rtk pnpm --dir frontend build
rtk cargo test --manifest-path third_party/easytier/easytier-contrib/easytier-ffi/Cargo.toml --locked
rtk bash scripts/build-easytier-ios.sh
rtk xcodebuild -project WhatsAppDeviceAgent.xcodeproj \
  -scheme WhatsAppDeviceAgent -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
rtk xcodebuild -project WhatsAppDeviceAgent.xcodeproj \
  -scheme PacketTunnel -destination 'generic/platform=iOS' build
rtk git diff --check
```

真机网络/WDA 能力不能由 simulator、mock 或单元测试替代。

CI 必须启动隔离 PostgreSQL 17 service，注入 `TEST_DATABASE_URL`，并让 iOS store integration test 在变量缺失时 `t.Fatal` 而不是 `t.Skip`；验收报告必须记录 `0 skipped`。部署前另执行：

```bash
rtk systemd-analyze verify /etc/systemd/system/whatsapp-ai-ios-controller.service
rtk test -c /dev/net/tun
rtk /opt/whatsapp_ai/ios-controller preflight --tun /dev/net/tun
rtk curl -fsS http://127.0.0.1:8790/health/ready
rtk curl -fsS http://127.0.0.1:8792/health/ready
```

## 19. 分阶段实施清单

### M0：真机技术门禁

- [ ] 固定 EasyTier/WDA 源码提交和许可证。
- [ ] 为 EasyTier FFI 增加 staticlib、空指针错误和 symbol 校验。
- [ ] 构建 XCFramework 和最小 PacketTunnel spike。
- [ ] 验证 TUN fd、EasyTier peer、Wi-Fi-only、蜂窝-only 和双向 `8100`。
- [ ] 完成 Wi-Fi/蜂窝切换及 WDA 脱离 USB/宿主 24 小时寿命测试。
- [ ] 固化 zh/en WhatsApp source fixture 和 selector profile。
- [ ] 验证重复正文、滚动、入站同文、人工触摸的 sent/unknown 口径及 click 后 unknown 故障。
- [ ] 扫描 EasyTier CLI/FFI 启动日志，确认 canary secret 不泄漏。
- [ ] 若选择 App Store 轨，完成 M0-E 公共 `NEPacketTunnelFlow` bridge 和 TestFlight 门禁；不把 WDA 激活归入该能力。
- [ ] 写 `docs/testing/2026-08-06-ios-easytier-wda-m0.md`。

### M1：数据库、RBAC 和 API

- [ ] 按第 10 章写 SQL 和 store migration。
- [ ] 先写失败的 store 并发/状态机/tenant 测试，再实现 store。
- [ ] 先写路由、鉴权、幂等、校验测试，再实现管理 API。
- [ ] 实现独立 Agent/Controller auth、lease renew/revoke/kill-switch 和契约测试。
- [ ] 扩展浏览器 WS 权限过滤。

### M2：美国控制器

- [ ] 实现固定 EasyTier 进程管理、统一配置脱敏和 secret-retire/re-enroll。
- [ ] 用 fake WDA 写 red-green 测试，证明 click 恰好一次。
- [ ] 实现 raw WDA client、session、selector、baseline/verify。
- [ ] 实现 lease/phase/result client 和 graceful shutdown。
- [ ] 完成 SSRF、timeout、body limit、日志脱敏测试。

### M3：生产 iOS App

- [ ] 建立 App/Extension targets、entitlements、App Group、Keychain group。
- [ ] 实现 enrollment、原子配置、VPN profile。
- [ ] 实现 PacketTunnel 生命周期和 EasyTier Bridge。
- [ ] 实现前台 WSS/status 上报及后台边界。
- [ ] 真机覆盖升级、token 轮换、飞行模式和配置损坏。

### M4：管理前端与小流量验收

- [ ] 新增 RBAC 菜单对应视图和 API client。
- [ ] 实现设备探活、群发创建、进度、unknown resolve。
- [ ] 使用内置浏览器验证 Console/Network/权限/重连并截图。
- [ ] 执行 1 设备 10 条、2 设备 100 条测试。
- [ ] 观察 24 小时，确认无重复、无跨租户、无 secret/正文日志。

## 20. 最终验收标准

全部满足才可声明“可落地已实现”：

1. iPhone 无第二个 VPN App，自研 App 内 EasyTier Core 正常运行。
2. 拔 USB、结束 Mac 启动进程后 24 小时，Wi-Fi-only、4G/5G-only 及至少两次承载切换下 WDA 均可从美国服务器访问；关闭 Wi-Fi 仅作为蜂窝专项测试，不是产品限制。
3. 美国服务器只用登记虚拟 IP `:8100` 完成 session/source/screenshot/click。
4. 发送动作无需用户逐条确认；测试消息 100 条无重复，sent 口径可复核。
5. click 后断网/崩溃得到 unknown 且自动重发次数为 0。
6. iPhone 重启/WDA 退出明确转 recovery_required，不返回假 online。
7. 同设备严格串行，多设备按上限并行；server/controller 重启后任务可恢复。
8. 租户、RBAC、Agent token、Controller token、CSRF 全部有负向测试。
9. 任意 API 输入不能让 controller 请求非登记 IP、非 8100 或公网目标。
10. 日志、指标、WS、审计、浏览器响应中无 token、secret、完整 phone/content/source/screenshot。
11. EasyTier LGPL 和 WDA LICENSE 交付物完整；App Store 轨只在公共 Packet Tunnel bridge/entitlement 门禁通过后声明可送审，不能声称 App Store App 激活 WDA。
12. `go test -race`（`TEST_DATABASE_URL` 非空且 0 skipped）、前端 test/lint/build、Rust test/build、iOS build/test、部署 preflight、`git diff --check` 全部通过，并有新鲜输出记录。

## 21. 关键决策记录

| 决策 | 采用 | 拒绝及理由 |
|---|---|---|
| iPhone VPN | 自研 App 内嵌 EasyTier FFI | 外装 WireGuard/EasyTier App：违背单 App 要求 |
| 网络隔离 | 共享 EasyTier 网络（`wa-ios`/`10.168.0.0/16`）+ ACL 限制 `:8100` 仅 controller 可达 | 每设备独立网络：管理/资源成本高，与用户单服务端共享网络基线不符 |
| 任务执行 | 美国 `ios-controller` | iOS 普通 App Agent：后台 WSS/执行不可靠且不能跨 App 自动化 |
| WDA 客户端 | Go 直接调用 WDA HTTP | Appium 常驻层：v1 增加不必要依赖，WDA 路由已足够 |
| TUN 接入 | v1 内部分发下 KVC fd + EasyTier `set_tun_fd`；App Store 轨改用 public packetFlow bridge | 把私有 KVC 直接送审；主 App 不能借此激活 WDA |
| 发送幂等 | click 前持久化边界，click 后不自动重试 | 盲目 retry：会重复发消息 |
| 在线判定 | controller 主动 WDA probe | App heartbeat：iOS 后台不可作为权威 |
| 旧群发 | 完全隔离 | 改造同步 send-many：状态语义和传输实现不兼容 |

## 22. 参考与实施复核点

- EasyTier 源码：<https://github.com/EasyTier/EasyTier/tree/v2.6.4>
- EasyTier FFI：`easytier-contrib/easytier-ffi/src/lib.rs`
- EasyTier iOS mobile cfg：`easytier/build.rs`、`easytier/src/instance/virtual_nic.rs`
- EasyTier LICENSE：<https://github.com/EasyTier/EasyTier/blob/v2.6.4/LICENSE>
- WebDriverAgent v16.1.5：<https://github.com/appium/WebDriverAgent/tree/v16.1.5>
- WDA routes：`WebDriverAgentLib/Commands/FBSessionCommands.m`、`FBElementCommands.m`、`FBDebugCommands.m`、`FBScreenshotCommands.m`
- Apple Network Extension：<https://developer.apple.com/documentation/networkextension/nepackettunnelprovider>
- Apple Developer Mode：<https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device>

实施前应再次核验固定提交的源码，而不是使用 `main`/`latest` 文档推断行为。本文中的 M0 是交付门禁，不是可在项目末尾补做的测试。
