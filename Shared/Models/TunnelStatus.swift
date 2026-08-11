import Foundation

/// Extension 状态快照（设计 6.5：只保存 peer 数、running、错误码和时间，不保存完整路由/peer JSON）。
/// 放在 Shared 供主 App 读取展示/上报（设计 6.8）。
struct TunnelStatusSnapshot: Codable, Equatable {
    var phase: TunnelPhase
    var virtualIP: String?
    var peerCount: Int
    var lastErrorCode: String?
    var updatedAt: Date

    init(phase: TunnelPhase,
         virtualIP: String? = nil,
         peerCount: Int = 0,
         lastErrorCode: String? = nil,
         updatedAt: Date = Date()) {
        self.phase = phase
        self.virtualIP = virtualIP
        self.peerCount = peerCount
        self.lastErrorCode = lastErrorCode
        self.updatedAt = updatedAt
    }
}

enum TunnelPhase: String, Codable {
    case connecting
    case connected
    case stopped
    case recoveryRequired
    case ffiNotConfigured
}
