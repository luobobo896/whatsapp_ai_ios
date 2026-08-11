import Foundation

/// Extension 状态快照（设计 6.5：只保存 peer 数、流量、延迟、错误码和时间，不保存完整路由/peer JSON）。
/// 放在 Shared 供主 App 读取展示/上报（设计 6.8）。
struct TunnelStatusSnapshot: Codable, Equatable {
    var phase: TunnelPhase
    var virtualIP: String?
    var peerCount: Int
    var lastErrorCode: String?
    /// 与 relay/peer 的累计下行字节（EasyTier peer conns stats 汇总）。
    var rxBytes: UInt64?
    /// 与 relay/peer 的累计上行字节。
    var txBytes: UInt64?
    /// 到 peer 的延迟（毫秒，取各连接的最大值）。
    var latencyMs: Int?
    /// 隧道进入 connected 的时刻（App 用于显示连接时间与已连接时长）。
    var connectedAt: Date?
    var updatedAt: Date

    init(phase: TunnelPhase,
         virtualIP: String? = nil,
         peerCount: Int = 0,
         lastErrorCode: String? = nil,
         rxBytes: UInt64? = nil,
         txBytes: UInt64? = nil,
         latencyMs: Int? = nil,
         connectedAt: Date? = nil,
         updatedAt: Date = Date()) {
        self.phase = phase
        self.virtualIP = virtualIP
        self.peerCount = peerCount
        self.lastErrorCode = lastErrorCode
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.latencyMs = latencyMs
        self.connectedAt = connectedAt
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
