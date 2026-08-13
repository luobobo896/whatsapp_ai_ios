/**
 * 从 whatsapp_ai_ios 复制：Shared/Models/AgentWSEnvelope.swift
 * WSS envelope 消息类型 / close code / payload / 路由（设计 §7.3）。
 * 注意：群发 task:dispatch 不在本协议中（§7.3）。
 */

import Foundation

/// 设计 §7.3 WSS envelope 消息类型。
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // 兼容带小数秒与不带小数秒两种 ISO 8601。
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date: \(value)"
            )
        }
        return decoder
    }()
}

/// WSS URL 构造：https -> wss，http -> ws，路径固定 /api/ios-agent/v1/ws（§7.2）。
enum AgentWSRoute {
    static let path = "/api/ios-agent/v1/ws"

    static func url(serverBaseURL: String) -> URL? {
        guard var components = URLComponents(string: serverBaseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path = path
        return components.url
    }
}
