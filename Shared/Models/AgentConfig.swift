import Foundation

/// 设备配置（非秘密字段），来源：设计文档 6.4 配置存储与 7.1 注册响应。
/// 明文 token / network secret 永不进入本结构，只存共享 Keychain。
struct AgentConfig: Codable, Equatable {
    var schemaVersion: Int
    var configVersion: Int
    var deviceId: String
    var networkName: String
    var networkCIDR: String
    var iphoneIPv4: String
    var relayHost: String
    var relayPort: Int
    var serverBaseURL: String
    var updatedAt: Date

    static let currentSchemaVersion = 1

    enum ValidationError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
        case invalidDeviceId
        case invalidNetworkName
        case invalidCIDR
        case invalidIPv4(String)
        case invalidRelayPort
        case invalidServerBaseURL
    }

    /// 扩展启动前必须通过校验（设计 6.4：校验失败不启动 VPN）。
    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard Self.isDeviceIDValid(deviceId) else { throw ValidationError.invalidDeviceId }
        guard Self.isNetworkNameValid(networkName) else { throw ValidationError.invalidNetworkName }
        guard Self.isCIDRValid(networkCIDR) else { throw ValidationError.invalidCIDR }
        guard Self.isIPv4Valid(iphoneIPv4) else { throw ValidationError.invalidIPv4(iphoneIPv4) }
        guard (1...65535).contains(relayPort) else { throw ValidationError.invalidRelayPort }
        guard Self.isServerBaseURLValid(serverBaseURL) else { throw ValidationError.invalidServerBaseURL }
    }

    /// deviceId 为 24 字符文本 id（设计 7.1）。
    static func isDeviceIDValid(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9-]{24}$"#, options: .regularExpression) != nil
    }

    /// networkName 只允许 [a-z0-9-]（设计 5.2 固定 wa-ios）。
    static func isNetworkNameValid(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil
    }

    /// 共享网段 10.168.0.0/16（设计 5.1）。
    static func isCIDRValid(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), prefix == 16,
              isIPv4Valid(String(parts[0])) else { return false }
        return isIPv4InPool(String(parts[0]))
    }

    static func isIPv4Valid(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let number = UInt8(octet) else { return false }
            return String(number) == octet // 拒绝前导零等非法形式
        }
    }

    static func isIPv4InPool(_ value: String) -> Bool {
        let octets = value.split(separator: ".")
        guard octets.count >= 2,
              let first = UInt8(octets[0]),
              let second = UInt8(octets[1]) else { return false }
        return first == 10 && second == 168
    }

    /// 服务器地址仅允许 HTTPS；开发构建额外允许 http://127.0.0.1（设计 6.7）。
    static func isServerBaseURLValid(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return url.host != nil }
        if scheme == "http" {
            let host = url.host?.lowercased()
            return host == "127.0.0.1" || host == "localhost"
        }
        return false
    }
}
