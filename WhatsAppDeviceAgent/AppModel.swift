import Combine
import CryptoKit
import Foundation

/// UI 状态协调。
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case enrolling
        case enrolled
        case failed(String)
    }

    /// 默认平台地址（HK 测试环境）；真机/模拟器打开即带默认值，可改。
    @Published var serverBaseURL = "https://hk.hsddns.com"
    @Published var enrollmentCode = ""
    @Published var phase: Phase = .idle
    @Published var currentConfig: AgentConfig?
    @Published var lastError: String?

    private let enrollmentService: EnrollmentService
    private let webSocket: AgentWebSocket
    private let logger = RedactingLogger(category: "app-model")
    private var heartbeatTask: Task<Void, Never>?

    init(enrollmentService: EnrollmentService? = nil) {
        // 在 @MainActor 隔离的 init 内创建默认依赖，避免默认参数在非隔离上下文求值。
        self.enrollmentService = enrollmentService ?? EnrollmentService()
        self.webSocket = AgentWebSocket()
        configureWebSocket()
    }

    /// 设备唯一 ID 短码（sha256(installationId) 前 12 位，与平台设备列表「设备 ID」一致，一一对应）。
    /// WDA 直连地址（局域网 IP + 8100），云平台直接访问（不依赖 VPN）。
    var wdaUrl: String? {
        DeviceNetwork.lanIPv4().map { "http://\($0):8100" }
    }

    var deviceIDShort: String {
        let id = enrollmentService.installationID()
        let digest = SHA256.hash(data: Data(id.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    var isEnrolled: Bool {
        if case .enrolled = phase { return currentConfig != nil }
        return false
    }

    /// 启动时从 App Group 恢复已保存配置（设计 6.4 原子写保证可恢复），并启动心跳/WSS 保持在线。
    /// 配置必须通过校验才进入已注册状态（设计 6.4：校验失败不进入已注册状态）。
    func restoreIfNeeded() {
        guard currentConfig == nil,
              let config = try? AppGroupStore.loadConfig(),
              (try? config.validate()) != nil else { return }
        currentConfig = config
        phase = .enrolled
        reportStatus(.online)
        startHeartbeat()
        startWebSocket()
    }

    func enroll() async {
        phase = .enrolling
        do {
            let config = try await enrollmentService.enroll(
                serverBaseURL: serverBaseURL,
                enrollmentCode: enrollmentCode
            )
            currentConfig = config
            phase = .enrolled
            lastError = nil
            reportStatus(.online)
            startHeartbeat()
            startWebSocket()
        } catch {
            let message: String
            if let apiErr = error as? AgentAPIError, case .httpStatus(401) = apiErr {
                message = "注册码已使用或过期，请在平台重新生成后重试。"
            } else {
                message = "注册失败：\(error.localizedDescription)"
            }
            phase = .failed(message)
            lastError = message
            logger.error("enroll failed: \(error.localizedDescription)")
        }
    }

    /// 上报 App 在线状态（前台心跳，设计 7.2 /status）。
    /// 下线：App 停止上报后，平台按 last_app_seen_at 超时窗口判离线。
    /// 前台周期心跳：每 20 秒上报一次在线状态，保证平台在线判定不误判（设计 6.8）。
    func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.reportStatus(.online)
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func reportStatus(_ status: AgentAppStatus = .online) {
        Task {
            guard let config = currentConfig,
                  let token = try? SharedKeychain.read(.deviceToken),
                  let url = URL(string: config.serverBaseURL) else { return }
            let client = AgentAPIClient(baseURL: url)
            // WDA 直连：上报局域网 IP 作为 WebDriverAgent 访问地址。
            let wdaUrl = DeviceNetwork.lanIPv4().map { "http://\($0):8100" }
            // VPN/组网已移除：隧道相关字段上报中性值，保持平台 /status 契约字段兼容。
            let snapshot = AgentStatus(
                appStatus: status,
                vpnPhase: "stopped",
                virtualIP: nil,
                peerCount: 0,
                lastErrorCode: nil,
                extensionUpdatedAt: nil,
                wdaUrl: wdaUrl
            )
            do {
                try await client.reportStatus(token: token, status: snapshot)
            } catch let error as AgentAPIError {
                // 设备被平台禁用/删除时 token 失效（401）→ 需要重新注册；其他错误下次心跳重试。
                if case .httpStatus(401) = error {
                    resetForReenrollment()
                    lastError = "设备已被平台移除，请重新注册。"
                }
            } catch {
                // 网络/信号不稳定：本次心跳失败不打断，下轮重试。
            }
        }
    }

    // MARK: - WSS 长连接（设计 6.8 / 7.2 / 7.3）

    /// 已注册且前台时连接平台 WSS（每 20s heartbeat；后台由 suspendWebSocket 暂停）。
    func startWebSocket() {
        guard isEnrolled,
              let token = try? SharedKeychain.read(.deviceToken),
              let config = currentConfig,
              let url = AgentWSRoute.url(serverBaseURL: config.serverBaseURL) else { return }
        webSocket.connect(url: url, token: token)
    }

    /// 前台转后台：发一次 app:suspended 后断开（§6.8）。
    func suspendWebSocket() {
        webSocket.suspend()
    }

    private func configureWebSocket() {
        webSocket.installationID = { [weak self] in self?.enrollmentService.installationID() ?? "" }
        webSocket.configVersion = { [weak self] in self?.currentConfig?.configVersion ?? 0 }
        webSocket.wdaURL = { [weak self] in self?.wdaUrl }
        webSocket.diagnosticPayload = { [weak self] in
            AgentWSPayload(
                configVersion: self?.currentConfig?.configVersion,
                appStatus: "online",
                wdaUrl: self?.wdaUrl
            )
        }
        webSocket.onConfigChanged = { [weak self] version in
            Task { [weak self] in await self?.applyRemoteConfig(configVersion: version) }
        }
        webSocket.onAuthFailure = { [weak self] code in
            self?.handleWSAuthFailure(code)
        }
    }

    /// server:config_changed -> GET /config 拉取新配置并落盘（§7.2/§7.3）。
    private func applyRemoteConfig(configVersion: Int) async {
        guard let config = currentConfig,
              let token = try? SharedKeychain.read(.deviceToken),
              let url = URL(string: config.serverBaseURL) else { return }
        let client = AgentAPIClient(baseURL: url)
        do {
            let newConfig = try await client.fetchConfig(token: token)
            // 设计 6.4：配置必须通过校验才落盘/应用；校验失败保留旧配置，等待下次补推。
            try newConfig.validate()
            try AppGroupStore.saveConfig(newConfig)
            currentConfig = newConfig
            lastError = nil
            webSocket.sendStatus(payload: AgentWSPayload(
                configVersion: newConfig.configVersion,
                appStatus: "online",
                wdaUrl: wdaUrl
            ))
        } catch {
            logger.error("config refresh failed: \(error.localizedDescription)")
        }
    }

    /// WSS 鉴权类关闭（§7.3 close code）。
    private func handleWSAuthFailure(_ code: AgentWSCloseCode) {
        switch code {
        case .tokenInvalid:
            resetForReenrollment()
            lastError = "设备已被平台移除，请重新注册。"
        case .deviceDisabled:
            webSocket.disconnect()
            lastError = "设备已被平台禁用。"
        case .replaced, .protocolError:
            // 被新连接替换或协议错误：不打断用户，由客户端重连。
            break
        }
    }

    /// 重新注册/退出：清除本地配置与 Keychain，返回注册页（设备被平台移除或用户主动重注册）。
    func resetForReenrollment() {
        stopHeartbeat()
        webSocket.disconnect()
        try? SharedKeychain.delete(.deviceToken)
        try? SharedKeychain.delete(.networkSecret)
        AppGroupStore.clear()
        currentConfig = nil
        phase = .idle
        lastError = nil
    }
}
