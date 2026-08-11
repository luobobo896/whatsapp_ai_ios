import Combine
import CryptoKit
import Foundation

/// UI 状态协调（设计 6.1：AppModel 不包含 FFI）。
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case enrolling
        case enrolled
        case failed(String)
    }

    /// 连接状态（真机组网后由 Extension 回调更新；模拟器/未组网为 idle/connecting）。
    enum VPNState: Equatable {
        case idle
        case connecting
        case connected
        case failed
    }

    /// 默认平台地址（HK 测试环境）；真机/模拟器打开即带默认值，可改。
    @Published var serverBaseURL = "https://hk.hsddns.com"
    @Published var enrollmentCode = ""
    @Published var phase: Phase = .idle
    @Published var currentConfig: AgentConfig?
    @Published var lastError: String?
    @Published var vpnState: VPNState = .idle
    @Published var serverLatency: String?

    private let enrollmentService: EnrollmentService
    private let vpnManager: VPNManager
    private let logger = RedactingLogger(category: "app-model")
    private var heartbeatTask: Task<Void, Never>?
    /// 隧道状态轮询：启动 VPN 后每 2 秒读取 Extension 写入 App Group 的状态快照，
    /// 让界面状态（vpnState）与真实隧道状态同步（设计 6.8）。
    private var statusPollTask: Task<Void, Never>?

    init(enrollmentService: EnrollmentService? = nil,
         vpnManager: VPNManager? = nil) {
        // 在 @MainActor 隔离的 init 内创建默认依赖，避免默认参数在非隔离上下文求值。
        self.enrollmentService = enrollmentService ?? EnrollmentService()
        self.vpnManager = vpnManager ?? VPNManager()
    }

    /// 设备唯一 ID 短码（sha256(installationId) 前 12 位，与平台设备列表「设备 ID」一致，一一对应）。
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
            do {
                try await vpnManager.saveProfile(configVersion: config.configVersion)
            } catch {
                // 模拟器/无签名环境 VPN profile 保存可能失败，不阻断注册闭环（真机正常）。
                logger.error("saveProfile failed: \(error.localizedDescription)")
                lastError = "注册成功，但 VPN profile 保存失败（模拟器/签名限制）。"
            }
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
            let snapshot = AgentStatus(
                appStatus: status,
                vpnPhase: reportedVPNPhase,
                virtualIP: config.iphoneIPv4,
                peerCount: 1
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
        stopStatusPolling()
        try? SharedKeychain.delete(.deviceToken)
        try? SharedKeychain.delete(.networkSecret)
        AppGroupStore.clear()
        currentConfig = nil
        phase = .idle
        lastError = nil
    }

    /// 配置下发成功门禁：配置校验通过且 token/networkSecret 已保存到 Keychain，
    /// 才允许启动 VPN（组网）。配置不完整/secret 丢失时禁止启动，提示重新注册。
    var isConfigReady: Bool {
        guard let config = currentConfig else { return false }
        guard (try? config.validate()) != nil else { return false }
        guard (try? SharedKeychain.read(.networkSecret)) != nil,
              (try? SharedKeychain.read(.deviceToken)) != nil else { return false }
        return true
    }

    func startVPN() {
        guard isConfigReady else {
            lastError = "配置未下发完成，请先完成注册后再启动 VPN。"
            return
        }
        guard let config = currentConfig else { return }
        vpnState = .connecting
        lastError = nil
        vpnManager.startTunnel(configVersion: config.configVersion)
        startStatusPolling()
    }

    func stopVPN() {
        vpnState = .idle
        stopStatusPolling()
        vpnManager.stopTunnel()
    }

    // MARK: - 隧道状态同步（设计 6.8）

    /// 启动 VPN 后轮询 Extension 状态快照，2 秒一次；界面状态随真实隧道状态更新。
    private func startStatusPolling() {
        guard statusPollTask == nil else { return }
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.syncVPNStateFromTunnel()
            }
        }
    }

    private func stopStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = nil
    }

    /// 读取 Extension 写入 App Group 的状态并映射到 UI 状态。
    /// 无错误码的 stopped 视为启动前初始状态，不把 connecting 打回 idle，避免闪烁。
    private func syncVPNStateFromTunnel() {
        guard let snapshot = try? AppGroupStore.readJSON(
            TunnelStatusSnapshot.self,
            from: AppGroupStore.statusFileName) else { return }
        switch snapshot.phase {
        case .connected:
            vpnState = .connected
            if lastError != nil { lastError = nil }
        case .connecting:
            vpnState = .connecting
        case .stopped, .recoveryRequired, .ffiNotConfigured:
            if let code = snapshot.lastErrorCode {
                vpnState = .failed
                lastError = code
            }
        }
    }

    /// 上报给平台的 vpnPhase 语义（设计 7.2 与 TunnelPhase 对齐）。
    private var reportedVPNPhase: String {
        switch vpnState {
        case .idle: return TunnelPhase.stopped.rawValue
        case .connecting: return TunnelPhase.connecting.rawValue
        case .connected: return TunnelPhase.connected.rawValue
        case .failed: return TunnelPhase.recoveryRequired.rawValue
        }
    }
}
