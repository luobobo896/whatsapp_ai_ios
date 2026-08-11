# 真机安装 iOS App 并注册到平台（HK 测试）SOP

> 目标：把 `WhatsAppDeviceAgent` 装到你的 iPhone，完成注册（enrollment）并在平台设备列表看到该设备。
> 环境：**HK 测试服务器**（`hk.hsddns.com`），禁止用生产 `us.hsddns.com`。
> 对应设计：方案 6.7（主 App 页面）、7.1（注册流程）、8.2（USB 激活）。

## 0. 前置条件

| 项 | 要求 |
|---|---|
| Mac | Xcode 26.3（已装），USB 数据线 |
| iPhone | iOS 16.4+，已开启「开发者模式」（设置 → 隐私与安全性 → 开发者模式），锁屏密码已设 |
| Apple ID | 已加入 Xcode 账号（免费也可，免费签名 7 天；付费开发者长期） |
| HK 平台 | 已部署支持 iOS 注册接口的 server（见 §5 阻塞点） |
| 仓库 | 分支 `feat/ios-whatsapp-broadcast-vpn`，Xcode 已能编译 |

## 1. iPhone 开发者模式

1. USB 连接 iPhone，在 iPhone 上点「信任此电脑」。
2. 设置 → 隐私与安全性 → 开发者模式 → 开启，按提示重启。
3. Xcode → Window → Devices and Simulators，能看到该 iPhone 即为配对成功。

## 2. Xcode 真机运行

1. 打开 `WhatsAppDeviceAgent.xcodeproj`。
2. 选中 `WhatsAppDeviceAgent` target → Signing & Capabilities → Team 选你的 Apple ID。
   - 免费账号下 bundle id `com.whatsappai.deviceagent` 无法直接签名：把 `Configs/Base.xcconfig` 的
     `APP_BUNDLE_ID`/`EXT_BUNDLE_ID`/`APP_GROUP_ID`/`KEYCHAIN_GROUP_ID` 成组改成你自己的前缀
     （如 `com.<你的id>.deviceagent`，四者必须成组修改，见方案 6.1）。
   - Network Extension 需要付费开发者账号的 entitlement；免费账号无法启用 `packet-tunnel-provider`，
     只能先验证注册流程（注册不依赖 VPN entitlement，启动 VPN 会失败）。
3. Scheme 选 `WhatsAppDeviceAgent`，设备选你的 iPhone，⌘R 运行。
4. 首次运行会请求安装；iPhone 上如提示「不受信任的开发者」，到 设置 → 通用 → VPN 与设备管理 信任该证书。

## 3. 平台创建设备并获取 enrollment code

1. 获取 iPhone UDID：Xcode → Window → Devices and Simulators 中设备详情里复制；或 `xcrun devicectl list devices`。
2. 浏览器打开 HK 测试平台（如 `https://hk.hsddns.com`），用测试管理员登录。
3. iOS 设备菜单 → 新建设备：
   - 名称、UDID（第 1 步获取）、WhatsApp 版本、locale（zh_CN / en_US）
   - 保存后页面返回一次性 enrollment code（16 位，形如 `9C4K-7Q2M-P8RX-H5TW`，10 分钟有效，只显示一次）。

## 4. App 注册

1. 打开 App → 注册页：
   - 平台地址：HK 测试地址（HTTPS；开发构建允许 `http://127.0.0.1`，真机必须用 HTTPS 或 hk 域名）
   - 一次性注册码：粘贴第 3 步的 code
2. 点「注册并启用 VPN」。
3. 成功判定：
   - App 进入「设备状态」页，显示 设备 ID / 配置版本 / 虚拟 IP（10.168.x.y）/ 对端 hk 地址
   - 平台 iOS 设备列表出现该设备，状态从 `pending_enrollment` → `vpn_connecting` →（组网成功后）`online`
4. 首次保存 VPN profile 时 iOS 弹系统 VPN 配置确认，点允许（一次性）。

## 5. 当前阻塞点（诚实说明）

- **平台端 iOS 注册 API 尚未实现**：方案 M1（数据库/RBAC/API）未开始，server 没有
  `POST /api/ios-agent/v1/enroll`、`GET /api/ios-agent/v1/config` 等路由。
  App 侧（`EnrollmentService`/`AgentAPIClient`/`EnrollmentView`）已就绪，但真机注册会得到 404。
- 因此「验证注册到平台」的**最小闭环**顺序是：
  1. 实现 M1 最小后端：`ios_devices` 表 + `POST /enroll` + `GET /config` + `POST /status`
     + 管理员创建设备接口（UDID → 分配 `10.168.0.0/16` 内固定 IP → 生成 code）
  2. 部署 HK：先 `./deploy-easytier-test.sh`（独立部署 easytier 服务端，`REMOTE=hk` 写死），再 `./deploy-test.sh`（server/connector，只拉 `origin/main-test`）
  3. 本 SOP 第 1-4 步真机验证注册 → 设备列表出现
- 组网/WDA 真机门禁（M0-B/C/D）仍需 iPhone 现场执行，见 `docs/testing/2026-08-06-ios-easytier-wda-m0.md`。

## 6. 安全与测试边界

- 本 SOP 只针对 **HK 测试环境**；生产 `us.hsddns.com` 不部署 iOS 测试功能（测试部署脚本均写死 `REMOTE=hk`）。
- enrollment code 只显示一次、10 分钟有效；`network_secret` 不在浏览器出现。
- 测试用真实号码发送前必须确认 opt-in；本 SOP 阶段只验证注册，不发送消息。
