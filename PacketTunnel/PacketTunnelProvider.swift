import NetworkExtension

enum PacketTunnelError: Error {
    /// easytier 组件已移除，VPN 数据面未实现。
    case easytierRemoved

    var errorCode: String {
        switch self {
        case .easytierRemoved: return "easytierRemoved"
        }
    }
}

/// Packet Tunnel 生命周期。
/// easytier 组件已从 App 移除（数据面待按官方 EasyTier-iOS 重新集成），
/// startTunnel 只写 App Group 状态并明确失败，不做伪在线。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = RedactingLogger(category: "packet-tunnel")

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        TunnelStatusReporter.write(TunnelStatusSnapshot(
            phase: .ffiNotConfigured,
            lastErrorCode: PacketTunnelError.easytierRemoved.errorCode))
        completionHandler(PacketTunnelError.easytierRemoved)
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        TunnelStatusReporter.write(TunnelStatusSnapshot(phase: .stopped))
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {}
}
