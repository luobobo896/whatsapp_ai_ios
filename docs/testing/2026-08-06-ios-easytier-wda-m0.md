# iOS EasyTier/WDA M0 真机门禁记录

> 对应方案 `docs/design/2026-08-06-ios-whatsapp-broadcast-vpn.md` 第 4 章（P0 门禁）与第 19 章 M0。
> 状态：**M0-A 构建/链接部分通过；真机部分待执行**。未全部通过前不得实现 M1 之后生产功能。

## 0. 环境与版本（2026-08-10）

| 项 | 版本 |
|---|---|
| 仓库分支 | `feat/ios-whatsapp-broadcast-vpn` |
| EasyTier | `v2.6.4` / `8428a89d2dabc94c97d370ec607c6ca142473626`（OpenWrt 包版本串一致） |
| Rust | 1.95.0（rustup minimal，iOS targets：aarch64-apple-ios / aarch64-apple-ios-sim / x86_64-apple-ios） |
| protoc | 35.1（Homebrew，easytier 依赖 prost 构建需要） |
| Xcode | 26.3（Build 17C529），iOS Simulator 26.3 runtime |
| 模拟器 | iPhone 17 Pro（iOS 26.3） |
| 用户参考基线 | new.hsddns.com / old.hsddns.com 的 OpenWrt easytier-core 2.6.4-8428a89d |

## 1. M0-A：EasyTier iOS XCFramework 与 TUN fd

### 1.1 已通过（构建/链接门禁）

1. **固定源码**：`third_party/easytier` 克隆到 v2.6.4 tag，`HEAD == 8428a89d...` 与 `Vendor/EasyTier/SOURCE_COMMIT` 一致。
2. **fork 最小修改**（方案 6.2，归档 `scripts/easytier-fork-v2.6.4-8428a89d.patch`）：
   - `easytier-ffi/Cargo.toml`：`crate-type=["staticlib","cdylib"]`；`easytier` 依赖 `default-features=false`，仅 `wireguard,websocket,smoltcp,tun`（排除 socks5/kcp/quic/faketcp/magic-dns/zstd）。
   - `easytier-ffi/src/lib.rs`：全部跨 FFI `assert!` 改为空指针/非法参数返回 `-1` 并写 `ERROR_MSG`；补充 null、无效 fd、重复 instance、释放字符串单测。
   - `easytier/src/core.rs`、`easytier/src/instance/instance.rs`：移除 `cfg.dump()` 完整明文配置日志，改为记录 instance name 与"config dump redacted"；修复 `magic-dns` feature 关闭后的 cfg 隔离编译错误。
3. **FFI 单元测试**：`cargo test -p easytier-ffi --locked` → **5/5 通过**（含新增 null/无效 fd/重复实例/释放字符串）。
4. **XCFramework**：`scripts/build-easytier-ios.sh` 成功；产物 `Vendor/EasyTier/EasyTierFFI.xcframework`（ios-arm64 + ios-arm64_x86_64-simulator）；SHA-256 `a6e651564b8aea5fc394d3ab8fdda0dbf5773f5aafa376bf931326ad65b05df6`。
5. **符号核验**：7 个基础 ABI（parse_config/run_network_instance/set_tun_fd/retain_network_instance/collect_network_infos/get_error_msg/free_string）全架构核验通过；public packetFlow 3 个符号为 M0-E fork 新增，当前 `REQUIRE_PACKET_FLOW=1` 才校验。
6. **iOS 链接**：PacketTunnel target 链接 XCFramework + SystemConfiguration.framework（easytier upnp 模块依赖），`EasyTierRuntime.isLinked=true`，`EASYTIER_FFI_LINKED` 编译条件开启；**Debug 与 Release 构建均 BUILD SUCCEEDED**。
7. **iOS 测试**：模拟器 `xcodebuild test` → 17/17 通过。

### 1.2 工具链注意事项（本机记录）

- `static.rust-lang.org` 在本网络 TLS 握手不稳定，rustup 下载组件需 `RUSTUP_DIST_SERVER=https://rsproxy.cn`。
- Xcode 26.3 的 `nm`/`llvm-nm` 无法解析 Rust 1.95（LLVM 22）object 元数据（Unknown attribute kind 105），但**链接器 ld 兼容**；符号校验脚本改用 `strings` 提取（见 `scripts/verify-easytier-ffi-symbols.sh` 注释）。
- `grep -q` 接管道 + `set -o pipefail` 会因上游 SIGPIPE 返回 141 导致误判，脚本已改用 `grep -x >/dev/null`。

### 1.3 待真机执行（未通过）

- [ ] 真机 `PacketTunnelProvider.startTunnel` 经 KVC 提取有效 TUN fd、`set_tun_fd` 返回 0、`collect_network_infos` running/peer 出现。
- [ ] 美国端 easytier 服务端（us.hsddns.com，单进程 config.toml，listener 11010/11011）能看到 iPhone peer。
- [ ] 双向 TCP 流量从美国节点进入 iPhone TUN 并到达本地 WDA `8100`。
- [ ] 服务端单实例多 peer（100/1000/5000 模拟）内存/fd/带宽实测，更新方案 5.6.3 容量基线。
- [ ] EasyTier ACL（v2.6.4）能力实测：仅 controller 访问设备 `:8100`，设备间互访拒绝。

## 2. M0-B1 / M0-B2 / M0-C / M0-D / M0-E

全部**未开始**，需真机 + 美国服务器 + 测试号码，按方案 4.2-4.6 执行后回填。

## 3. 结论

M0-A 的"编译 → 静态库 → XCFramework → 符号核验 → iOS 链接"链路已闭环；剩余为真机网络/WDA 门禁，属硬件现场验证，不替代。
