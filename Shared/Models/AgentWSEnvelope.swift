import Foundation

/// 设计 §7.3 WSS envelope 消息类型。
/// 注意：群发 `task:dispatch` 明确不在此协议中（§7.3），群发由平台 ios-controller
/// 通过 App 上报的 wdaUrl 直连 WDA 驱动，不经 App 侧 WSS。
enum AgentWSMessageType: String, Codable, Equatable {
    case hello = "agent:hello"
    case heartbeat = "agent:heartbeat"
    case status = "agent:status"
    /// §6.8：App 进入后台时发送一次，随后允许断开。
    case suspended = "app:suspended"
    case ack = "server:ack"
    case configChanged = "server:config_changed"
    case diagnosticRequest = "server:diagnostic_request"
    case disconnect = "server:disconnect"
}

/// 设计 §7.3 WSS close code。
enum AgentWSCloseCode: Int, Equatable {
    case tokenInvalid = 4001
    case replaced = 4002
    case deviceDisabled = 4003
    case protocolError = 4004
}

/// §7.3 各消息的 payload 字段（全部可选，JSON 缺省即可，双向容错）。
struct AgentWSPayload: Codable, Equatable {
    var app: String?
    var os: String?
    var model: String?
    var locale: String?
    var configVersion: Int?
    var foreground: Bool?
    var vpnPhase: String?
    var peerCount: Int?
    var appStatus: String?
    var lastErrorCode: String?
    var wdaUrl: String?
    var requestId: String?
    var ackedMsgId: String?
    var reason: String?
}

/// 设计 §7.3 WSS envelope（所有文本帧）。
struct AgentWSEnvelope: Codable, Equatable {
    var v: Int = 1
    var type: AgentWSMessageType
    var msgId: String
    var sentAt: Date
    var payload: AgentWSPayload = AgentWSPayload()

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// WSS URL 构造：https -> wss，http -> ws，路径固定 /api/ios-agent/v1/ws（§7.2）。
enum AgentWSRoute {
    static let path = "/api/ios-agent/v1/ws"

    static func url(serverBaseURL: String) -> URL? {
        guard var comps = URLComponents(string: serverBaseURL) else { return nil }
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "http": comps.scheme = "ws"
        default: return nil
        }
        comps.path = path
        return comps.url
    }
}
