import Foundation

enum AgentAPIError: Error, Equatable {
    case invalidServerURL
    case httpStatus(Int)
    case decodingFailed
    case emptyResponse
}

/// 注册请求（设计 7.1）。
struct EnrollRequest: Encodable, Equatable {
    var enrollmentCode: String
    var installationId: String
    var appVersion: String
    var osVersion: String
    var deviceModel: String
    var locale: String
    var platform: String
    /// 开发签名包读取的真实 UDID 列表（embedded.mobileprovision，可能多台）。
    var deviceUdids: [String]
}

/// 注册成功响应（设计 7.1），token/secret 仅本次返回明文。
struct EnrollResponse: Decodable, Equatable {
    var deviceId: String
    var deviceToken: String
    var config: EnrollConfig

    struct EnrollConfig: Decodable, Equatable {
        var schemaVersion: Int
        var configVersion: Int
        var networkName: String
        var networkCIDR: String
        var iphoneIPv4: String
        var relayHost: String
        var relayPort: Int
        var networkSecret: String
    }
}

/// /api/ios-agent/v1 设备 API client（设计 7.2）。
struct AgentAPIClient {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = AgentAPIClient.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// 默认会话带显式超时：心跳 20s 一次，避免慢网络下请求无限堆积。
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// 只允许 HTTPS；开发构建额外允许 http://127.0.0.1（设计 6.7）。
    static func validateServerURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" { return url.host == nil ? nil : url }
        if scheme == "http" {
            let host = url.host?.lowercased()
            return host == "127.0.0.1" || host == "localhost" ? url : nil
        }
        return nil
    }

    func enroll(request: EnrollRequest) async throws -> EnrollResponse {
        let url = baseURL.appendingPathComponent("api/ios-agent/v1/enroll")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let data = try await perform(urlRequest)
        do {
            return try JSONDecoder().decode(EnrollResponse.self, from: data)
        } catch {
            throw AgentAPIError.decodingFailed
        }
    }

    /// GET /config 只返回非秘密字段；App 补充自己的 serverBaseURL（设计 7.2）。
    func fetchConfig(token: String) async throws -> AgentConfig {
        let url = baseURL.appendingPathComponent("api/ios-agent/v1/config")
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(urlRequest)
        do {
            let remote = try JSONDecoder().decode(RemoteAgentConfig.self, from: data)
            return AgentConfig(
                schemaVersion: remote.schemaVersion,
                configVersion: remote.configVersion,
                deviceId: remote.deviceId,
                networkName: remote.networkName,
                networkCIDR: remote.networkCIDR,
                iphoneIPv4: remote.iphoneIPv4,
                relayHost: remote.relayHost,
                relayPort: remote.relayPort,
                serverBaseURL: baseURL.absoluteString,
                updatedAt: Date()
            )
        } catch {
            throw AgentAPIError.decodingFailed
        }
    }

    func reportStatus(token: String, status: AgentStatus) async throws {
        let url = baseURL.appendingPathComponent("api/ios-agent/v1/status")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(status)
        _ = try await perform(urlRequest)
    }

    func rotateToken(token: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/ios-agent/v1/token/rotate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(urlRequest)
        struct RotateResponse: Decodable { var deviceToken: String }
        guard let response = try? JSONDecoder().decode(RotateResponse.self, from: data) else {
            throw AgentAPIError.decodingFailed
        }
        return response.deviceToken
    }

    private func perform(_ urlRequest: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AgentAPIError.httpStatus(http.statusCode)
        }
        return data
    }

    /// 远端 config 响应（不含 serverBaseURL）。
    private struct RemoteAgentConfig: Decodable {
        var schemaVersion: Int
        var configVersion: Int
        var deviceId: String
        var networkName: String
        var networkCIDR: String
        var iphoneIPv4: String
        var relayHost: String
        var relayPort: Int
    }
}
