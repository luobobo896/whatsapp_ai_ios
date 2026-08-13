/**
 * 从 whatsapp_ai_ios 复制：Shared/Networking/AgentWebSocket.swift
 * 设计 §6.8 / §7.3：App 侧 WSS 长连接客户端。
 * - 前台连接，每 20s 发送 `agent:heartbeat`；进入后台发一次 `app:suspended` 后断开（§6.8）。
 * - 收到 `server:config_changed` -> onConfigChanged；`server:diagnostic_request` -> 用 `agent:status` 应答；
 *   关闭码 4001/4003 -> onAuthFailure，其余按退避重连（前台）。
 * - 附：5s ping 测延迟，提供 onStateChanged / onMetricsChanged 供连接状态页展示。
 */

import Foundation
import UIKit

@MainActor
final class AgentWebSocket {
    static let heartbeatInterval: TimeInterval = 20
    private static let pingInterval: UInt64 = 5_000_000_000
    private static let reconnectBackoff: [UInt64] = [1, 2, 4, 8, 16, 30]

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingURL: URL?
    private var pendingToken: String?
    private var reconnectIndex = 0
    private var msgCounter = 0
    private var running = false
    private var manualClose = false

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
    /// 连接状态（供状态页）。
    var onStateChanged: ((WDAAgentSocketState) -> Void)?
    /// 延迟/上下行字节/连接时间（供状态页）。
    var onMetricsChanged: ((TimeInterval?, Int64, Int64, Date?) -> Void)?

    private(set) var latency: TimeInterval?
    private(set) var downloadBytes: Int64 = 0
    private(set) var uploadBytes: Int64 = 0
    private(set) var connectedAt: Date?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 生命周期

    /// 连接并保持（前台）。已连接时忽略。
    func connect(url: URL, token: String) {
        pendingURL = url
        pendingToken = token
        if !running {
            downloadBytes = 0
            uploadBytes = 0
            connectedAt = nil
            latency = nil
        }
        running = true
        manualClose = false
        guard task == nil else { return }
        startTask(url: url, token: token)
    }

    /// 前台转后台：发一次 `app:suspended` 后关闭，停止心跳与重连（§6.8）。
    func suspend() {
        running = false
        manualClose = false
        send(.suspended, payload: AgentWSPayload(foreground: false))
        let activeTask = task
        stopWorkers()
        task = nil
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            activeTask?.cancel(with: .normalClosure, reason: Data("background".utf8))
        }
        connectedAt = nil
        latency = nil
        publishMetrics()
        updateState(.stopped)
    }

    /// 主动断开（重新注册/退出），不再重连。
    func disconnect() {
        running = false
        manualClose = true
        pendingURL = nil
        pendingToken = nil
        let activeTask = task
        task = nil
        stopWorkers()
        activeTask?.cancel(with: .normalClosure, reason: Data("disconnect".utf8))
        connectedAt = nil
        latency = nil
        publishMetrics()
        updateState(.stopped)
    }

    /// 主动上报一次状态（注册完成/状态变化时调用）。
    func sendStatus(payload: AgentWSPayload) {
        send(.status, payload: payload)
    }

    // MARK: - 内部

    private func startTask(url: URL, token: String) {
        stopWorkers()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let webSocketTask = session.webSocketTask(with: request)
        task = webSocketTask
        webSocketTask.resume()
        logger.info("WSS 连接: \(url.host ?? "")")
        updateState(reconnectIndex == 0 ? .connecting : .reconnecting)
        send(.hello, payload: AgentWSPayload(
            app: "WebDriverAgentRunner",
            os: UIDevice.current.systemVersion,
            model: UIDevice.current.model,
            locale: Locale.current.identifier,
            configVersion: configVersion()
        ))
        startReceive(for: webSocketTask)
        startHeartbeat()
        startPings(for: webSocketTask)
    }

    private func startReceive(for webSocketTask: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask else { return }
            while !Task.isCancelled {
                do {
                    let message = try await webSocketTask.receive()
                    guard self.task === webSocketTask else { return }
                    switch message {
                    case .string(let text):
                        self.downloadBytes += Int64(text.utf8.count)
                        self.handle(text)
                    case .data(let data):
                        self.downloadBytes += Int64(data.count)
                    @unknown default:
                        break
                    }
                    self.publishMetrics()
                } catch {
                    break // 连接结束
                }
            }
            guard !Task.isCancelled else { return }
            self.handleDisconnect(webSocketTask)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.send(.heartbeat, payload: AgentWSPayload(
                    foreground: true,
                    vpnPhase: "stopped",
                    peerCount: 0,
                    appStatus: "online",
                    wdaUrl: self.wdaURL()
                ))
            }
        }
    }

    private func startPings(for webSocketTask: URLSessionWebSocketTask) {
        ping(webSocketTask)
        pingTask?.cancel()
        pingTask = Task { [weak self, weak webSocketTask] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingInterval)
                guard !Task.isCancelled, let self, let webSocketTask else { return }
                self.ping(webSocketTask)
            }
        }
    }

    private func ping(_ webSocketTask: URLSessionWebSocketTask) {
        let startedAt = Date()
        webSocketTask.sendPing { [weak self, weak webSocketTask] error in
            Task { @MainActor in
                guard let self, let webSocketTask, self.task === webSocketTask else { return }
                if error != nil {
                    self.handleDisconnect(webSocketTask)
                    return
                }
                self.latency = Date().timeIntervalSince(startedAt)
                self.markConnected()
            }
        }
    }

    private func markConnected() {
        reconnectIndex = 0
        if connectedAt == nil { connectedAt = Date() }
        updateState(.connected)
        publishMetrics()
    }

    private func send(_ type: AgentWSMessageType, payload: AgentWSPayload) {
        guard let webSocketTask = task else { return }
        msgCounter += 1
        let envelope = AgentWSEnvelope(
            type: type,
            msgId: "\(installationID()):\(msgCounter)",
            sentAt: Date(),
            payload: payload
        )
        guard let data = try? AgentWSEnvelope.jsonEncoder.encode(envelope),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask else { return }
            do {
                try await webSocketTask.send(.string(text))
                guard self.task === webSocketTask else { return }
                self.uploadBytes += Int64(data.count)
                self.markConnected()
            } catch {
                self.logger.error("WSS 发送失败: \(error.localizedDescription)")
                self.handleDisconnect(webSocketTask)
            }
        }
    }

    private func handle(_ text: String) {
        guard let envelope = try? AgentWSEnvelope.jsonDecoder.decode(
            AgentWSEnvelope.self,
            from: Data(text.utf8)
        ) else {
            logger.error("WSS 帧解析失败")
            return
        }
        switch envelope.type {
        case .ack:
            break
        case .configChanged:
            if let version = envelope.payload.configVersion {
                onConfigChanged?(version)
            }
        case .diagnosticRequest:
            if let requestID = envelope.payload.requestId {
                var payload = diagnosticPayload()
                payload.requestId = requestID
                send(.status, payload: payload)
            }
        case .disconnect:
            if let reason = envelope.payload.reason {
                logger.info("WSS server:disconnect: \(reason)")
            }
        case .hello, .heartbeat, .status, .suspended:
            break // 服务器不应下发这些类型，忽略
        }
    }

    private func handleDisconnect(_ webSocketTask: URLSessionWebSocketTask) {
        guard task === webSocketTask else { return }
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pingTask?.cancel()
        pingTask = nil
        connectedAt = nil
        latency = nil
        publishMetrics()

        let rawClose = webSocketTask.closeCode.rawValue
        if let closeCode = AgentWSCloseCode(rawValue: rawClose),
           closeCode == .tokenInvalid || closeCode == .deviceDisabled {
            running = false
            onAuthFailure?(closeCode)
            stopWorkers()
            return
        }
        if manualClose || !running {
            updateState(.stopped)
            return
        }
        // 前台且未主动关闭：退避重连（§7.3 close 4002 被新连接替换时也直接重连）
        updateState(.reconnecting)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let seconds = Self.reconnectBackoff[min(reconnectIndex, Self.reconnectBackoff.count - 1)]
        reconnectIndex = min(reconnectIndex + 1, Self.reconnectBackoff.count - 1)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.running, self.task == nil,
                  let url = self.pendingURL, let token = self.pendingToken else { return }
            self.startTask(url: url, token: token)
        }
    }

    private func stopWorkers() {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func updateState(_ state: WDAAgentSocketState) {
        onStateChanged?(state)
    }

    private func publishMetrics() {
        onMetricsChanged?(latency, downloadBytes, uploadBytes, connectedAt)
    }
}
