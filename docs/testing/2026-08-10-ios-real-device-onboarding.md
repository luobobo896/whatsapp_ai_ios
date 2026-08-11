# iPhone 真机接入 HK 测试平台（注册 + 组网验证）指南

> 目标：真机安装 WhatsApp Device Agent，完成「注册 → 平台下发配置 → 启动 VPN → easytier 组网 → 双向可达」完整闭环验证。
> 适用：`feat/ios-whatsapp-broadcast-vpn` 分支（HK 测试环境，不涉及生产 us）。
> 状态：M3 组网接线（`PacketTunnelProvider` fd 轨）已完成，本指南按当前代码编写。

## 1. 硬前提（缺一不可）

| 前提 | 说明 |
| --- | --- |
| **付费 Apple Developer Program 账号** | Network Extension（VPN）是受限 entitlement，**免费个人 Team 无法签名**。免费账号在保存 VPN profile 时会报 `IPC failed / NEConfigurationErrorDomain Code 11`。 |
| Xcode 16+，macOS | 打开工程编译运行 |
| iPhone 真机（iOS 16.4+） | 模拟器无 TUN 设备，**组网只能在真机验证**；模拟器注册请用手动输入注册码（无摄像头，扫码仅真机可用） |
| 手机网络可达 HK | `https://hk.hsddns.com`（平台）与 `hk.hsddns.com:11010`（easytier UDP/TCP） |

## 2. 一次性签名配置（Xcode 内操作，约 5 分钟）

1. 打开工程：`WhatsAppDeviceAgent/WhatsAppDeviceAgent.xcodeproj`。
2. 顶部 Scheme 选 `WhatsAppDeviceAgent`。
3. 依次选中 target `WhatsAppDeviceAgent` 和 `PacketTunnel`，进入 **Signing & Capabilities**：
   - 勾选你的 Apple Team（Automatic signing）。
   - `WhatsAppDeviceAgent`：添加 **App Groups**（`group.com.whatsappai.deviceagent`）+ **Keychain Sharing**（`$(AppIdentifierPrefix)com.whatsappai.deviceagent.shared`）。
   - `PacketTunnel`：添加 **Network Extensions**（勾选 Packet Tunnel）+ **App Groups** + **Keychain Sharing**（同上）。
   - ⚠️ 若 Team 替换 bundle 前缀，`Configs/Base.xcconfig` 里的 `APP_BUNDLE_ID`/`EXT_BUNDLE_ID`/`APP_GROUP_ID`/`KEYCHAIN_GROUP_ID` 必须成组修改（设计 6.1）。
4. 编译验证：真机 Destination 选你的 iPhone，Cmd+R 运行；首次会弹「信任此电脑」。

## 3. 安装与信任

1. iPhone 用数据线连 Mac，解锁并「信任此电脑」。
2. Xcode 顶部 Destination 选真机 → Run，首次安装后：
   - 设置 → 通用 → VPN 与设备管理 → 找到开发者 App → 点「信任」。
3. 再次 Run 即可打开 App。

## 4. 平台准备：生成注册码 + 二维码

1. 浏览器打开 `https://hk.hsddns.com/whtasapp/`（HK 测试平台）。
2. 「设备」→「添加设备」（创建移动设备），平台会生成**一次性注册码 + 二维码**。
   - 注册码有效期 10 分钟，过期在平台重新生成即可（同一租户码可复用）。

## 5. App 注册

1. 打开 App，初始页是注册引导页：
   - 大按钮「扫码注册」→ 扫平台二维码；或
   - 「手动输入注册码」→ 粘贴/输入注册码（**平台地址默认已填 `https://hk.hsddns.com`**）。
2. 点「注册并启用 VPN」→ 注册成功自动进入设备页（显示你的虚拟 IP，如 `10.168.1.5`）。


## 6. 启动 VPN（组网）

1. 设备页中央大按钮「启动」（蓝色电源键）。
2. iOS 首次弹「允许 VPN 配置」→ 允许。
3. 30 秒内连接成功 → 按钮变绿「停止」，状态卡：
   - 状态：已连接
   - 服务器：`hk.hsddns.com:11010`
   - 虚拟 IP：`10.168.1.x`
   - 延迟：显示 easytier 对端延迟（有值 = 双向可达）
4. 平台设备列表对应设备状态应显示「在线」，虚拟 IP 一致。

## 7. 组网验证（双向可达）

在 HK 服务器（`ssh hk`）上：

```bash
# 1) 服务器 easytier 能看到手机 peer（lat 有值 = 双向连通）
/opt/whatsapp_ai/vendor/easytier/v2.6.4/easytier-cli -p 127.0.0.1:15888 peer list

# 2) 服务器 → 手机 方向 ping（10.168.1.x 换成 App 状态卡的虚拟 IP）
ping -c 4 10.168.1.x
```

- 服务器固定虚拟 IP：`10.168.0.1`（组网服务端）。
- 手机 → 服务器方向：easytier `peer list` 中 `lat(ms)` 有值即双向可达；若需 ICMP ping，可在 App 后续版本内置连通性探测（当前未内置）。

## 8. 常见问题与排错

| 现象 | 原因 / 处理 |
| --- | --- |
| 保存 VPN profile 报 `IPC failed` | 免费开发者账号无法签 Network Extension → 换付费账号（第 1 节） |
| 注册码提示无效/过期 | 10 分钟 TTL，平台重新生成 |
| 启动后一直「连接中」→ 失败 | 手机网络无法连 `hk.hsddns.com:11010`；或 easytier 服务端未运行（`ssh hk` 查 `/opt/whatsapp_ai/vendor/easytier/v2.6.4/easytier-core --config-file /etc/whatsapp-ai/easytier.toml`） |
| 启动失败错误码 | 见 App Group 状态文件 `tunnel-status.json` 的 `lastErrorCode`：`configUnavailable`/`secretUnavailable`（重新注册）/`parseConfigFailed`/`runInstanceFailed`/`setTunFDFailed`/`connectionTimeout` |
| 断开后重连 | 重新点「启动」；`wake` 后 30 秒无 peer 会自动触发系统重连 |

## 9. 当前代码状态（M3 接线）

- ✅ fd 轨（Development/Ad Hoc，Debug 配置）：`PacketTunnelProvider` 已按设计 6.5 固定顺序接线 `parse_config → run_network_instance → set_tun_fd → collect_network_infos`。
- ⏳ App Store 轨（Release，`packetFlow`）：`PacketFlowBridge` 尚未接入（M0-E），Release 启动 VPN 会明确失败，不伪在线。
- ℹ️ 本项目 VPN 只路由 `10.168.0.0/16`，不接管默认流量，不影响手机上其它代理/VPN；on-demand 关闭，全部手动启停。
