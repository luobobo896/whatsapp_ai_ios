import Foundation
import UIKit

/// 注册流程（设计 7.1）：enroll -> 保存 Keychain(token/secret) -> 保存 App Group 配置。
/// 不重试已消费 code；恢复路径由管理员重新签发 enrollment code。
struct EnrollmentService {
    /// 设备稳定唯一 ID：Keychain 持久化，同一台手机永远一致（重装也不变）。
    /// 平台按此 ID upsert，注册/登录始终只有一行数据。
    var installationID: () -> String = {
        if let existing = try? SharedKeychain.read(.installationID), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        try? SharedKeychain.store(id, for: .installationID)
        return id
    }
    var systemInfo: () -> (appVersion: String, iosVersion: String, deviceModel: String, locale: String) = {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return (
            appVersion: appVersion,
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            locale: Locale.current.identifier
        )
    }

    func enroll(serverBaseURL: String, enrollmentCode: String) async throws -> AgentConfig {
        guard let url = AgentAPIClient.validateServerURL(serverBaseURL) else {
            throw AgentAPIError.invalidServerURL
        }
        let info = systemInfo()
        let request = EnrollRequest(
            enrollmentCode: enrollmentCode,
            installationId: installationID(),
            appVersion: info.appVersion,
            osVersion: info.iosVersion,
            deviceModel: info.deviceModel,
            locale: info.locale,
            platform: "ios"
        )
        let client = AgentAPIClient(baseURL: url)
        let response = try await client.enroll(request: request)

        // 配置下发完整才算注册成功：networkSecret 缺失视为下发失败，不进入已注册状态。
        guard !response.deviceToken.isEmpty, !response.config.networkSecret.isEmpty else {
            throw AgentAPIError.decodingFailed
        }

        // token/secret 仅本次明文，保存到共享 Keychain（设计 7.1 / 6.4）。
        try SharedKeychain.store(response.deviceToken, for: .deviceToken)
        try SharedKeychain.store(response.config.networkSecret, for: .networkSecret)

        var config = AgentConfig(
            schemaVersion: response.config.schemaVersion,
            configVersion: response.config.configVersion,
            deviceId: response.deviceId,
            networkName: response.config.networkName,
            networkCIDR: response.config.networkCIDR,
            iphoneIPv4: response.config.iphoneIPv4,
            relayHost: response.config.relayHost,
            relayPort: response.config.relayPort,
            serverBaseURL: url.absoluteString,
            updatedAt: Date()
        )
        try config.validate()
        try AppGroupStore.saveConfig(config)
        return config
    }
}
