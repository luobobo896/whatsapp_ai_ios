import Foundation

/// WSS envelope（设计 7.3）。
struct AgentWSSEnvelope: Codable, Equatable {
    var v: Int
    var type: String
    var msgId: String
    var sentAt: String
    var payload: [String: String]?

    static func make(type: String, msgId: String, payload: [String: String]?) -> AgentWSSEnvelope {
        AgentWSSEnvelope(
            v: 1,
            type: type,
            msgId: msgId,
            sentAt: ISO8601DateFormatter().string(from: Date()),
            payload: payload
        )
    }
}

/// 设备 WSS（设计 7.3）：仅前台状态上报与轻量命令，不承担群发任务。
/// 每 20 秒 heartbeat；进入后台时发送一次 app:suspended 后允许断开（设计 6.8）。
final class AgentWebSocket: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var sequence = 0

    func connect(url: URL, token: String) async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let wsTask = session.webSocketTask(with: request)
        wsTask.resume()
        task = wsTask
    }

    func send(_ envelope: AgentWSSEnvelope) async throws {
        guard let task else { throw AgentAPIError.invalidServerURL }
        let data = try JSONEncoder().encode(envelope)
        guard let string = String(data: data, encoding: .utf8) else { throw AgentAPIError.decodingFailed }
        try await task.send(.string(string))
    }

    /// 前台 20 秒心跳循环（设计 7.3 允许类型 agent:heartbeat）。
    func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.sequence += 1
                let envelope = AgentWSSEnvelope.make(
                    type: "agent:heartbeat",
                    msgId: "\(self.sequence)",
                    payload: ["foreground": "true"]
                )
                _ = try? await self.send(envelope)
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        // 服务端关闭码 4001..4004 语义见设计 7.3；close 后清理。
        task = nil
    }
}
