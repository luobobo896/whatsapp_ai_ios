import Foundation
import NetworkExtension

enum VPNManagerError: Error {
    case profileSaveFailed(Error)
    case tunnelStartFailed(Error)
    case extensionNotFound
}

/// 保存唯一 VPN profile 并启停（设计 6.6）。
/// providerConfiguration 只放 schemaVersion/configVersion，不放 secret/token。
@MainActor
final class VPNManager {
    static let providerBundleID = "com.whatsappai.deviceagent.packet-tunnel"

    func saveProfile(configVersion: Int) async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID
        }) ?? NETunnelProviderManager()
        manager.protocolConfiguration = Self.providerProtocol(configVersion: configVersion)
        manager.localizedDescription = "WhatsApp Device Agent VPN"
        manager.isEnabled = true
        // 关闭 on-demand：NEOnDemandRuleConnect 无条件自动连接会干扰用户其他代理/VPN，
        // 本 App 的 VPN 完全由用户/App 手动启动（设计 6.6 已同步）。
        manager.isOnDemandEnabled = false
        manager.onDemandRules = []
        do {
            try await manager.saveToPreferences()
        } catch {
            throw VPNManagerError.profileSaveFailed(error)
        }
    }

    func startTunnel(configVersion: Int) {
        Task {
            guard let session = await Self.currentSession() else { return }
            do {
                try session.startVPNTunnel(options: ["configVersion": NSNumber(value: configVersion)])
            } catch {
                // 状态错误通过 DeviceStatusView 展示；不静默吞掉。
                RedactingLogger(category: "vpn").error("startTunnel failed: \(error.localizedDescription)")
            }
        }
    }

    func stopTunnel() {
        Task {
            await Self.currentSession()?.stopTunnel()
        }
    }

    /// 构造 provider protocol（可单测的纯函数）。
    static func providerProtocol(configVersion: Int) -> NETunnelProviderProtocol {
        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = providerBundleID
        protocolConfig.serverAddress = "EasyTier"
        protocolConfig.providerConfiguration = [
            "schemaVersion": 1,
            "configVersion": configVersion,
        ]
        return protocolConfig
    }

    private static func currentSession() async -> NETunnelProviderSession? {
        guard let manager = try? await loadManager() else { return nil }
        return manager.connection as? NETunnelProviderSession
    }

    private static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID
        })
    }
}
