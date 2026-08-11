#if EASYTIER_IO_PACKET_FLOW
import Foundation
import NetworkExtension

/// App Store 轨的 public packetFlow 双向桥（设计 6.2.1）。
/// 只通过 NEPacketTunnelFlow.readPackets/writePackets 回调桥接 EasyTier，
/// 禁止调用 set_tun_fd / TunnelFileDescriptor / fd KVC。
///
/// 开发前置准备阶段仅在 Release 配置编译；接入 XCFramework 后实现：
/// 1. set_packet_flow_io 注册 Rust callback（Unmanaged context）
/// 2. readPackets 受控循环：上一批全部成功 push 后才继续读；-EAGAIN 保留批次每 10ms 重试
/// 3. callback 只做锁内 copy/enqueue，drain 每批最多 64 个 packet 调 writePackets
/// 4. backlog 上限 2 MiB，超 5 秒未清空 -> cancelTunnelWithError(EASYTIER_PACKET_BACKPRESSURE)
final class PacketFlowBridge {
    private let packetFlow: NEPacketTunnelFlow

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func start() {
        // TODO(M0-E / M3): 启动 readPackets 循环与 Rust output callback。
        preconditionFailure("PacketFlowBridge 尚未接入 EasyTier FFI")
    }

    func stop() {
        // TODO(M0-E / M3): 停止 read -> close_packet_flow_io -> 清空队列。
    }
}
#endif
