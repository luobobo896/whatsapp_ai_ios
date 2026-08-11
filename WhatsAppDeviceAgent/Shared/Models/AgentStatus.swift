import Foundation

/// App/Extension 上报的状态快照（设计 7.2 /status、6.8 后台边界）。
struct AgentStatus: Codable, Equatable {
    /// App 主状态（enrollment_required、vpn_connecting、connected、recovery_required 等语义）。
    var appStatus: AgentAppStatus
    /// 描述 VPN/隧道当前阶段，尽量使用 TunnelPhase.rawValue。
    var vpnPhase: String
    /// 虚拟 IP（如 10.168.1.5），连接后非空。
    var virtualIP: String?
    var peerCount: Int
    /// 稳定错误码（如 TUN_FD_UNAVAILABLE、EASYTIER_PACKET_BACKPRESSURE）。
    var lastErrorCode: String?
    /// 最近一次 Extension 写入状态的时间戳。
    var extensionUpdatedAt: Date?

    init(appStatus: AgentAppStatus = .unknown,
         vpnPhase: String = "",
         virtualIP: String? = nil,
         peerCount: Int = 0,
         lastErrorCode: String? = nil,
         extensionUpdatedAt: Date? = nil) {
        self.appStatus = appStatus
        self.vpnPhase = vpnPhase
        self.virtualIP = virtualIP
        self.peerCount = peerCount
        self.lastErrorCode = lastErrorCode
        self.extensionUpdatedAt = extensionUpdatedAt
    }
}

/// App 主状态。值与服务端 /status 约定的语义对应（设计 1.2、4.1、7.2）。
enum AgentAppStatus: String, Codable, CaseIterable {
    case enrollmentRequired
    case vpnConnecting
    case online
    case connected
    case stopped
    case recoveryRequired
    case tunFDUNAvailable
    case ffiNotConfigured
    case unknown
}
