import Foundation

/// App 上报的状态快照（设计 7.2 /status、6.8 后台边界）。
struct AgentStatus: Codable, Equatable {
    /// App 主状态（enrollment_required、online、connected、recovery_required 等语义）。
    var appStatus: AgentAppStatus
    /// VPN/组网已移除：字段保留以兼容平台契约，固定上报 "stopped"。
    var vpnPhase: String
    /// VPN/组网已移除：固定为 nil。
    var virtualIP: String?
    /// VPN/组网已移除：固定为 0。
    var peerCount: Int
    /// VPN/组网已移除：固定为 nil。
    var lastErrorCode: String?
    /// VPN/组网已移除：固定为 nil。
    var extensionUpdatedAt: Date?
    /// WebDriverAgent 直连地址（`http://<局域网IP>:8100`），云平台直接访问，不依赖 VPN。
    var wdaUrl: String?

    init(appStatus: AgentAppStatus = .unknown,
         vpnPhase: String = "stopped",
         virtualIP: String? = nil,
         peerCount: Int = 0,
         lastErrorCode: String? = nil,
         extensionUpdatedAt: Date? = nil,
         wdaUrl: String? = nil) {
        self.appStatus = appStatus
        self.vpnPhase = vpnPhase
        self.virtualIP = virtualIP
        self.peerCount = peerCount
        self.lastErrorCode = lastErrorCode
        self.extensionUpdatedAt = extensionUpdatedAt
        self.wdaUrl = wdaUrl
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
