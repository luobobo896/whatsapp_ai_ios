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
    private let logger = RedactingLogger(category: "app-model")
    private var heartbeatTask: Task<Void, Never>?

    init(enrollmentService: EnrollmentService? = nil) {
        // 在 @MainActor 隔离的 init 内创建默认依赖，避免默认参数在非隔离上下文求值。
        self.enrollmentService = enrollmentService ?? EnrollmentService()
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

    /// 启动时从 App Group 恢复已保存配置（设计 6.4 原子写保证可恢复），并启动心跳保持在线。
    func restoreIfNeeded() {
        guard currentConfig == nil, let config = try? AppGroupStore.loadConfig() else { return }
        currentConfig = config
        phase = .enrolled
        reportStatus(.online)
        startHeartbeat()
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

    /// 重新注册/退出：清除本地配置与 Keychain，返回注册页（设备被平台移除或用户主动重注册）。
    func resetForReenrollment() {
        stopHeartbeat()
        try? SharedKeychain.delete(.deviceToken)
        try? SharedKeychain.delete(.networkSecret)
        AppGroupStore.clear()
        currentConfig = nil
        phase = .idle
        lastError = nil
    }
}
