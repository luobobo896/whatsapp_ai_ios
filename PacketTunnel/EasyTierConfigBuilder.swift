import Foundation

/// 结构化字段 -> EasyTier TOML（设计 5.4）。
/// 主 App 根据服务端下发的结构化配置生成 TOML，不接受服务端直接下发任意 TOML。
enum EasyTierConfigBuilder {
    struct Input: Equatable {
        var instanceName: String
        var hostname: String
        var ipv4: String
        var relayHost: String
        var relayPort: Int
        var networkName: String
        var networkSecret: String
        var mtu: Int = 1380
    }

    enum BuildError: Error, Equatable {
        case emptyInstanceName
        case invalidIPv4(String)
        case invalidRelayPort
        case emptyRelayHost
        case invalidMTU
    }

    static func toml(_ input: Input) throws -> String {
        guard !input.instanceName.isEmpty else { throw BuildError.emptyInstanceName }
        // 方案 5.4：EasyTier TOML 的 ipv4 为带 /16 前缀的地址（如 10.168.1.5/16）。
        guard AgentConfig.isCIDRValid(input.ipv4) else { throw BuildError.invalidIPv4(input.ipv4) }
        guard !input.relayHost.isEmpty else { throw BuildError.emptyRelayHost }
        guard (1...65535).contains(input.relayPort) else { throw BuildError.invalidRelayPort }
        guard (1280...9000).contains(input.mtu) else { throw BuildError.invalidMTU }

        var lines: [String] = []
        lines.append("instance_name = \"\(tomlEscape(input.instanceName))\"")
        lines.append("hostname = \"\(tomlEscape(input.hostname))\"")
        lines.append("ipv4 = \"\(tomlEscape(input.ipv4))\"")
        lines.append("dhcp = false")
        lines.append("listeners = []")
        lines.append("")
        lines.append("[network_identity]")
        lines.append("network_name = \"\(tomlEscape(input.networkName))\"")
        lines.append("network_secret = \"\(tomlEscape(input.networkSecret))\"")
        lines.append("")
        lines.append("[[peer]]")
        lines.append("uri = \"udp://\(tomlEscape(input.relayHost)):\(input.relayPort)\"")
        lines.append("")
        lines.append("[[peer]]")
        lines.append("uri = \"tcp://\(tomlEscape(input.relayHost)):\(input.relayPort)\"")
        lines.append("")
        lines.append("[flags]")
        lines.append("enable_ipv6 = false")
        lines.append("use_smoltcp = true")
        lines.append("bind_device = false")
        lines.append("mtu = \(input.mtu)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// TOML 基本字符串转义（双引号、反斜杠、控制字符）。
    static func tomlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
