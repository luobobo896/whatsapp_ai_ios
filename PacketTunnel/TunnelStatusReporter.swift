import Foundation

/// 写入 App Group 的隧道状态，供主 App 展示与上报（设计 6.8：Packet Tunnel 持续运行并把状态写入 App Group）。
/// 快照类型 TunnelStatusSnapshot / TunnelPhase 定义在 Shared/Models/TunnelStatus.swift。
enum TunnelStatusReporter {
    static func write(_ snapshot: TunnelStatusSnapshot) {
        try? AppGroupStore.writeJSON(snapshot, to: AppGroupStore.statusFileName)
    }

    static func read() -> TunnelStatusSnapshot? {
        try? AppGroupStore.readJSON(TunnelStatusSnapshot.self, from: AppGroupStore.statusFileName)
    }
}
