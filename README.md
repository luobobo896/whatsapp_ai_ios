# whatsapp_ai_ios

iOS 移动设备代理（WhatsApp Device Agent）独立仓库 —— 由 whatsapp_ai 主仓迁移而来。
iPhone App + Network Extension（PacketTunnel）通过 easytier 组网接入平台 `10.168.0.0/16` 虚拟网络，
注册/配置下发/心跳/组网状态走平台 `/api/ios-agent/v1` 接口。

## 仓库结构

```text
WhatsAppDeviceAgent/    Xcode 工程（App + PacketTunnel Extension + 测试）
scripts/                EasyTier iOS XCFramework 构建脚本与 fork patch
docs/                   设计 / 测试 / 部署文档
```

## 快速开始

1. 打开 `WhatsAppDeviceAgent/WhatsAppDeviceAgent.xcodeproj`（需要 Xcode 16+）。
2. 首次克隆后先构建 EasyTier FFI（XCFramework 为构建产物、不入库），见
   [`WhatsAppDeviceAgent/README.md`](WhatsAppDeviceAgent/README.md) 的「构建 EasyTier FFI」。
3. 模拟器：直接 Run，注册用手动输入注册码（模拟器无摄像头）。
4. 真机：Signing 填 Apple Team、iPhone 开启开发者模式；Network Extension（VPN）需付费开发者账号。

## 文档

- 设计：`docs/design/2026-08-06-ios-whatsapp-broadcast-vpn.md`（主设计）、
  `docs/design/2026-08-04-iphone-whatsapp-broadcast-feasibility.md`（可行性）、
  `docs/design/2026-08-10-ios-solution-review.md`（方案评审）
- 测试：`docs/testing/2026-08-10-ios-real-device-onboarding.md`（真机接入 HK 测试平台）、
  `docs/testing/2026-08-06-ios-easytier-wda-m0.md`
- 部署：`docs/deployment/ios-device-enroll-test-sop.md`

## 与平台主仓（whatsapp_ai）的关系

- 接口契约：`/api/ios-agent/v1`（enroll / config / status / token/rotate）；平台默认 `https://hk.hsddns.com`。
- easytier 服务端运维（`deploy-easytier-test.sh`、HK 服务器部署）属平台侧，不在本仓库。
