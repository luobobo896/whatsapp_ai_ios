import Foundation
import UIKit

/// 设计 §6.8 / §7.3：App 侧 WSS 长连接客户端。
/// - 前台连接，每 20s 发送 `agent:heartbeat`；进入后台发一次 `app:suspended` 后断开（§6.8）。
/// - 收到 `server:config_changed` -> onConfigChanged（App 随后 GET /config）；
///   `server:diagnostic_request` -> 用 `agent:status` 应答无敏感诊断；
///   关闭码 4001/4003 -> onAuthFailure（token 失效/设备禁用），其余按退避重连（前台）。
/// - 群发 task:dispatch 不在此协议（§7.3），平台经 wdaUrl 直连 WDA 驱动，不经本通道。
@MainActor
final class AgentWebSocket {
    static let heartbeatInterval: TimeInterval = 20
    private static let reconnectBackoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var msgCounter = 0
    private var running = false      // 期望保持连接（已登录且前台）
    private var manualClose = false
    private var pendingURL: URL?
    private var pendingToken: String?

    private let logger = RedactingLogger(category: "agent-ws")

    /// 注入：installationId（msgId 前缀）、configVersion（hello）、WDA 地址（status）、诊断信息。
    var installationID: () -> String = { "" }
    var configVersion: () -> Int = { 0 }
    var wdaURL: () -> String? = { nil }
    var diagnosticPayload: () -> AgentWSPayload = { AgentWSPayload() }

    /// 平台下发配置版本变更（App 随后 GET /config）。
    var onConfigChanged: ((Int) -> Void)?
    /// 平台诊断请求 requestId。
    var onDiagnosticRequest: ((String) -> Void)?
    /// 鉴权类关闭（4001 token 无效 / 4003 设备禁用）。
    var onAuthFailure: ((AgentWSCloseCode) -> Void)?
    /// 连接被对端关闭（非鉴权类）。
    var onDisconnected: (() -> Void)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 生命周期

    /// 连接并保持（前台）。已连接时忽略。
    func connect(url: URL, token: String) {
        running = true
        manualClose = false
        pendingURL = url
        pendingToken = token
        guard task == nil else { return }
        startTask(url: url, token: token)
    }

    /// 前台转后台：发一次 `app:suspended` 后关闭，停止心跳与重连（§6.8）。
    func suspend() {
        running = false
        send(.suspended, payload: AgentWSPayload(foreground: false))
        let t = task
        // 给发送帧一点 flush 时间再关
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            t?.cancel(with: .normalClosure, reason: Data("background".utf8))
        }
        stopTimers()
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    /// 主动断开（重新注册/退出），不再重连。
    func disconnect() {
        running = false
        manualClose = true
        pendingURL = nil
        pendingToken = nil
        close(code: .normalClosure, reason: "disconnect")
    }

    /// 主动上报一次状态（注册完成/状态变化时调用）。
    func sendStatus(payload: AgentWSPayload) {
        send(.status, payload: payload)
    }

    // MARK: - 内部

    private func startTask(url: URL, token: String) {
        cancelTimers()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        logger.info("WSS 连接: \(url.host ?? "")")
        send(.hello, payload: AgentWSPayload(
            app: "WhatsAppDeviceAgent",
            os: UIDevice.current.systemVersion,
            model: UIDevice.current.model,
            locale: Locale.current.identifier,
            configVersion: configVersion()
        ))
        startReceive()
        startHeartbeat()
    }

    private func startReceive() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self, let task = self.task else { return }
            while !Task.isCancelled {
                do {
                    switch try await task.receive() {
                    case .string(let text): self.handle(text)
                    case .data: break
                    @unknown default: break
                    }
                } catch {
                    break // 连接结束
                }
            }
            guard !Task.isCancelled else { return }
            self.handleDisconnect(closeCode: task.closeCode)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.send(.heartbeat, payload: self.heartbeatPayload())
            }
        }
    }

    private func heartbeatPayload() -> AgentWSPayload {
        AgentWSPayload(
            foreground: true,
            vpnPhase: "stopped",
            peerCount: 0,
            appStatus: "online",
            wdaUrl: wdaURL()
        )
    }

    private func handle(_ text: String) {
        guard let env = try? AgentWSEnvelope.jsonDecoder.decode(AgentWSEnvelope.self,
                                                               from: Data(text.utf8)) else {
            logger.error("WSS 帧解析失败")
            return
        }
        switch env.type {
        case .ack:
            break
        case .configChanged:
            if let v = env.payload.configVersion {
                onConfigChanged?(v)
            }
        case .diagnosticRequest:
            if let rid = env.payload.requestId {
                var p = diagnosticPayload()
                p.requestId = rid
                send(.status, payload: p)
            }
        case .disconnect:
            // 仅记录；服务器随后会关闭连接，由 receive 循环的断连路径统一处理。
            if let reason = env.payload.reason {
                logger.info("WSS server:disconnect: \(reason)")
            }
        case .hello, .heartbeat, .status, .suspended:
            break // 服务器不应下发这些类型，忽略
        }
    }

    private func handleDisconnect(closeCode: URLSessionWebSocketTask.CloseCode) {
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        let wsClose = AgentWSCloseCode(rawValue: closeCode.rawValue)
        if let wsClose, wsClose == .tokenInvalid || wsClose == .deviceDisabled {
            onAuthFailure?(wsClose)
            stopTimers()
            return
        }
        if manualClose || !running {
            return
        }
        // 前台且未主动关闭：退避重连（§7.3 close 4002 被新连接替换时也直接重连）
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            // 前台运行期间持续退避重连，不因一轮退避结束而放弃。
            while self.running && self.task == nil {
                for delay in Self.reconnectBackoff {
                    guard self.running, self.task == nil else { return }
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard self.running, self.task == nil else { return }
                    if let url = self.pendingURL, let token = self.pendingToken {
                        self.startTask(url: url, token: token)
                        return
                    }
                }
            }
        }
    }

    private func send(_ type: AgentWSMessageType, payload: AgentWSPayload) {
        guard task != nil else { return }
        msgCounter += 1
        let env = AgentWSEnvelope(
            type: type,
            msgId: "\(installationID()):\(msgCounter)",
            sentAt: Date(),
            payload: payload
        )
        guard let data = try? AgentWSEnvelope.jsonEncoder.encode(env),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error {
                self?.logger.error("WSS 发送失败: \(error.localizedDescription)")
            }
        }
    }

    private func close(code: URLSessionWebSocketTask.CloseCode, reason: String) {
        manualClose = true
        stopTimers()
        let t = task
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        t?.cancel(with: code, reason: Data(reason.utf8))
    }

    private func stopTimers() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func cancelTimers() {
        stopTimers()
    }
}
