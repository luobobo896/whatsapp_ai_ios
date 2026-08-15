import Foundation
import Security
import UIKit
import Darwin

struct WDAAgentConfig: Codable, Equatable {
    var schemaVersion: Int
    var configVersion: Int
    var deviceId: String
    var networkName: String
    var networkCIDR: String
    var iphoneIPv4: String
    var relayHost: String
    var relayPort: Int
    var serverBaseURL: String
    var updatedAt: Date

    static let currentSchemaVersion = 1

    enum ValidationError: LocalizedError {
        case unsupportedSchemaVersion
        case invalidDeviceId
        case invalidNetworkName
        case invalidCIDR
        case invalidIPv4
        case invalidRelayPort
        case invalidServerBaseURL

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion: return "配置版本不受支持"
            case .invalidDeviceId: return "设备 ID 无效"
            case .invalidNetworkName: return "网络名称无效"
            case .invalidCIDR: return "网络地址无效"
            case .invalidIPv4: return "虚拟 IP 无效"
            case .invalidRelayPort: return "服务器端口无效"
            case .invalidServerBaseURL: return "平台地址无效"
            }
        }
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion
        }
        guard deviceId.range(of: #"^[a-z0-9-]{24}$"#, options: .regularExpression) != nil else {
            throw ValidationError.invalidDeviceId
        }
        guard networkName.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else {
            throw ValidationError.invalidNetworkName
        }
        guard Self.isCIDRValid(networkCIDR) else { throw ValidationError.invalidCIDR }
        guard Self.isIPv4Valid(iphoneIPv4), Self.isIPv4InPool(iphoneIPv4) else {
            throw ValidationError.invalidIPv4
        }
        guard (1...65535).contains(relayPort) else { throw ValidationError.invalidRelayPort }
        guard Self.isServerBaseURLValid(serverBaseURL) else {
            throw ValidationError.invalidServerBaseURL
        }
    }

    static func isIPv4Valid(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let number = UInt8(octet) else { return false }
            return String(number) == octet
        }
    }

    static func isIPv4InPool(_ value: String) -> Bool {
        let octets = value.split(separator: ".")
        guard octets.count >= 2 else { return false }
        return octets[0] == "10" && octets[1] == "168"
    }

    static func isCIDRValid(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "16" else { return false }
        return isIPv4Valid(String(parts[0])) && isIPv4InPool(String(parts[0]))
    }

    static func isServerBaseURLValid(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return false
        }
        if scheme == "https" { return url.host != nil }
        if scheme == "http" {
            let host = url.host?.lowercased()
            return host == "127.0.0.1" || host == "localhost"
        }
        return false
    }
}

enum WDAAgentAppStatus: String, Codable {
    case enrollmentRequired
    case online
    case connected
    case stopped
    case recoveryRequired
    case unknown
}

struct WDAAgentStatus: Codable {
    var appStatus: WDAAgentAppStatus
    var vpnPhase = "stopped"
    var virtualIP: String? = nil
    var peerCount = 0
    var lastErrorCode: String? = nil
    var extensionUpdatedAt: Date? = nil
    var wdaUrl: String? = nil
}

enum WDAAgentAPIError: LocalizedError, Equatable {
    case invalidServerURL
    case httpStatus(Int)
    case invalidResponse
    case missingSecrets
    case missingDeviceUDID

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "服务器地址无效（仅支持 https，开发构建可用 localhost）"
        case .httpStatus(let status):
            return "服务器返回 HTTP \(status)"
        case .invalidResponse:
            return "服务器响应格式无效"
        case .missingSecrets:
            return "服务器未返回完整的设备凭据"
        case .missingDeviceUDID:
            return "未获取到当前 USB 真机 UDID（WDA_DEVICE_UDID 未注入），请由本地网关「激活」启动后重试"
        }
    }
}

private struct WDAEnrollRequest: Encodable {
    var enrollmentCode: String
    var installationId: String
    var appVersion: String
    var osVersion: String
    var deviceModel: String
    var locale: String
    var platform: String
    var deviceUdids: [String]
}

private struct WDAEnrollResponse: Decodable {
    struct Config: Decodable {
        var schemaVersion: Int
        var configVersion: Int
        var networkName: String
        var networkCIDR: String
        var iphoneIPv4: String
        var relayHost: String
        var relayPort: Int
        var networkSecret: String
    }

    var deviceId: String
    var deviceToken: String
    var config: Config
}

private struct WDARemoteAgentConfig: Decodable {
    var schemaVersion: Int
    var configVersion: Int
    var deviceId: String
    var networkName: String
    var networkCIDR: String
    var iphoneIPv4: String
    var relayHost: String
    var relayPort: Int
}

private struct WDAAgentAPIClient {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    static func validateServerURL(_ string: String) -> URL? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WDAAgentConfig.isServerBaseURLValid(value) else { return nil }
        return URL(string: value)
    }

    func enroll(_ request: WDAEnrollRequest) async throws -> WDAEnrollResponse {
        var urlRequest = URLRequest(url: endpoint("enroll"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let data = try await perform(urlRequest)
        guard let response = try? JSONDecoder().decode(WDAEnrollResponse.self, from: data) else {
            throw WDAAgentAPIError.invalidResponse
        }
        return response
    }

    func fetchConfig(token: String) async throws -> WDAAgentConfig {
        var request = URLRequest(url: endpoint("config"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        guard let remote = try? JSONDecoder().decode(WDARemoteAgentConfig.self, from: data) else {
            throw WDAAgentAPIError.invalidResponse
        }
        return WDAAgentConfig(
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
    }

    func reportStatus(token: String, status: WDAAgentStatus) async throws {
        var request = URLRequest(url: endpoint("status"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(status)
        _ = try await perform(request)
    }

    private func endpoint(_ component: String) -> URL {
        baseURL.appendingPathComponent("api/ios-agent/v1/\(component)")
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WDAAgentAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw WDAAgentAPIError.httpStatus(http.statusCode)
        }
        return data
    }
}

private enum WDAAgentKeychain {
    static let service = "com.wda.WebRunner.agent"
    private static let simulatorPrefix = "wdaRunner.simulatorKeychain."

    enum Key: String {
        case deviceToken = "agent.device_token"
        case networkSecret = "agent.network_secret"
        case installationID = "agent.installation_id"
    }

    enum KeychainError: Error {
        case status(OSStatus)
        case invalidData
    }

    static func store(_ value: String, for key: Key) throws {
#if targetEnvironment(simulator)
        UserDefaults.standard.set(value, forKey: simulatorPrefix + key.rawValue)
#else
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemCopyMatching(match as CFDictionary, nil)
        if status == errSecSuccess {
            let update = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.status(update) }
            return
        }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var insert = match
        attributes.forEach { insert[$0.key] = $0.value }
        let add = SecItemAdd(insert as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError.status(add) }
#endif
    }

    static func read(_ key: Key) throws -> String {
#if targetEnvironment(simulator)
        guard let value = UserDefaults.standard.string(forKey: simulatorPrefix + key.rawValue),
              !value.isEmpty else {
            throw KeychainError.invalidData
        }
        return value
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
#endif
    }

    static func delete(_ key: Key) {
#if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: simulatorPrefix + key.rawValue)
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
#endif
    }
}

private enum WDAAgentStore {
    private static let fileName = "wda-agent-config.json"

    static func save(_ config: WDAAgentConfig) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(config).write(to: fileURL(), options: .atomic)
    }

    static func load() throws -> WDAAgentConfig? {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WDAAgentConfig.self, from: Data(contentsOf: url))
    }

    static func clear() {
        guard let url = try? fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("WDARunnerAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(fileName)
    }
}

private enum WDADeviceInfo {
    static func installationID() -> String {
        if let existing = try? WDAAgentKeychain.read(.installationID), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        try? WDAAgentKeychain.store(value, for: .installationID)
        return value
    }

    static func provisionedUDIDs() -> [String] {
        // 只取当前 USB 连接的真机 UDID（不写死、不读描述文件的多台列表）：
        //   1) 环境变量 WDA_DEVICE_UDID（Mac 侧 start-wda.sh 自动探测 USB 设备后注入）
        //   2) 启动参数 -WDA_DEVICE_UDID <udid>
        print("[UDID-1] provisionedUDIDs() 入口（仅 USB 真机 UDID）")
        let candidates: [(String, String)] = [
            ("env WDA_DEVICE_UDID", ProcessInfo.processInfo.environment["WDA_DEVICE_UDID"] ?? ""),
            ("launch -WDA_DEVICE_UDID", Self.launchArgumentUDID()),
        ]
        for (source, raw) in candidates {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if value.isEmpty { continue }
            print("[UDID-3] 来源=\(source)，原始=\(raw)")
            guard value.range(of: #"^[0-9A-F-]{20,40}$"#, options: .regularExpression) != nil else {
                print("[UDID-4] \(source) 格式不合法（\(raw)），尝试下一来源")
                continue
            }
            print("[UDID-5] 校验通过，返回当前 USB 真机 UDID [\(value)]（来源 \(source)）")
            return [value]
        }
        // 3) 兜底：App 自己签名包 embedded.mobileprovision 的 ProvisionedDevices
        //    （即当前这台设备的真实 UDID；Xcode ⌘U 直接运行时无 Mac 注入，靠它兜底）
        let profileUDIDs = provisionedUDIDsFromProfile()
        print("[UDID-6] profile 兜底读到 ProvisionedDevices=\(profileUDIDs)")
        if !profileUDIDs.isEmpty {
            print("[UDID-5] 使用 profile 兜底 UDID [\(profileUDIDs.joined(separator: ","))]")
            return profileUDIDs
        }
        print("[UDID-2] 所有来源均未提供合法 UDID，返回空，enroll 将报 missingDeviceUDID")
        return []
    }

    /// 从 embedded.mobileprovision 读取 ProvisionedDevices（沿 Bundle 向上找 Runner.app 的 profile）。
    private static func provisionedUDIDsFromProfile() -> [String] {
        var roots = [Bundle.main.bundleURL]
        roots.append(contentsOf: Bundle.allBundles.map(\.bundleURL))
        roots.append(contentsOf: Bundle.allFrameworks.map(\.bundleURL))
        var profilePaths = Set<String>()
        var devices = Set<String>()
        for root in roots {
            var directory = root.standardizedFileURL
            for _ in 0..<8 {
                let profile = directory.appendingPathComponent("embedded.mobileprovision")
                if profilePaths.insert(profile.path).inserted,
                   let values = provisionedUDIDs(from: profile) {
                    devices.formUnion(values)
                }
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { break }
                directory = parent
            }
        }
        return devices.sorted()
    }

    private static func provisionedUDIDs(from profileURL: URL) -> [String]? {
        guard FileManager.default.fileExists(atPath: profileURL.path),
              let data = try? Data(contentsOf: profileURL),
              let plistData = extractPlistData(from: data),
              let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ) as? [String: Any],
              let values = plist["ProvisionedDevices"] as? [String] else {
            return nil
        }
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func extractPlistData(from profileData: Data) -> Data? {
        let startMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = profileData.range(of: startMarker),
              let end = profileData.range(of: endMarker, in: start.upperBound..<profileData.endIndex) else {
            return nil
        }
        return profileData.subdata(in: start.lowerBound..<end.upperBound)
    }

    /// 读取启动参数 `-WDA_DEVICE_UDID <udid>`。
    private static func launchArgumentUDID() -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-WDA_DEVICE_UDID"), idx + 1 < args.count else {
            return ""
        }
        return args[idx + 1]
    }



    static func wdaURL() -> String? {
        lanIPv4().map { "http://\($0):8100" }
    }

    private static func lanIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }

        var wifi: String?
        var cellular: String?
        var fallback: String?
        var pointer = addresses
        while let current = pointer {
            let interface = current.pointee
            defer { pointer = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "pdp_ip0" || name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let value = String(cString: host)
            guard value != "127.0.0.1", !value.hasPrefix("169.254") else { continue }
            if name == "en0" { wifi = wifi ?? value }
            else if name == "pdp_ip0" { cellular = cellular ?? value }
            else { fallback = fallback ?? value }
        }
        return wifi ?? cellular ?? fallback
    }
}

enum WDAAgentSocketState: Equatable {
    case stopped
    case connecting
    case connected
    case reconnecting
}

@MainActor
final class WDAAgentModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case enrolling
        case enrolled
        case failed(String)
    }

    static let shared = WDAAgentModel()

    @Published var serverBaseURL = "https://hk.hsddns.com"
    @Published var enrollmentCode = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentConfig: WDAAgentConfig?
    @Published private(set) var socketState: WDAAgentSocketState = .stopped
    @Published private(set) var latency: TimeInterval?
    @Published private(set) var downloadBytes: Int64 = 0
    @Published private(set) var uploadBytes: Int64 = 0
    @Published private(set) var connectedAt: Date?
    @Published private(set) var connectionEnabled = false
    @Published private(set) var lastError: String?

    private let webSocket = AgentWebSocket()
    private var heartbeatTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    private init() {
        configureWebSocket()
        observeLifecycle()
        applyLaunchArguments()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    var isEnrolled: Bool {
        currentConfig != nil && phase == .enrolled
    }

    var wdaURL: String? { WDADeviceInfo.wdaURL() }

    var serverAddress: String {
        guard let config = currentConfig else { return "--" }
        return "\(config.relayHost):\(config.relayPort)"
    }

    var virtualIP: String { currentConfig?.iphoneIPv4 ?? "--" }

    var connectionText: String {
        guard connectionEnabled else { return "已停止" }
        switch socketState {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .stopped: return "未连接"
        }
    }

    func restoreIfNeeded() -> Bool {
        guard currentConfig == nil else { return isEnrolled }
        guard let config = try? WDAAgentStore.load() else { return false }
        do {
            try config.validate()
            _ = try WDAAgentKeychain.read(.deviceToken)
            currentConfig = config
            serverBaseURL = config.serverBaseURL
            phase = .enrolled
            connectionEnabled = true
            startServices()
            return true
        } catch {
            WDAAgentStore.clear()
            WDAAgentKeychain.delete(.deviceToken)
            WDAAgentKeychain.delete(.networkSecret)
            return false
        }
    }

    func applyScannedPayload(_ payload: String) {
        let value = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            enrollmentCode = ""
            return
        }

        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = object["enrollmentCode"] as? String ?? object["code"] as? String
            let server = object["serverBaseURL"] as? String ?? object["serverUrl"] as? String
            if let code, !code.isEmpty { enrollmentCode = code }
            if let server, WDAAgentAPIClient.validateServerURL(server) != nil { serverBaseURL = server }
            if code != nil { return }
        }

        if let components = URLComponents(string: value), components.scheme != nil {
            let items = components.queryItems ?? []
            let code = items.first { $0.name == "enrollmentCode" || $0.name == "code" }?.value
            let server = items.first { $0.name == "serverBaseURL" || $0.name == "serverUrl" }?.value
            if let code, !code.isEmpty {
                enrollmentCode = code
                if let server, WDAAgentAPIClient.validateServerURL(server) != nil { serverBaseURL = server }
                return
            }
        }
        enrollmentCode = value
    }

    func enroll() async {
        guard phase != .enrolling else { return }
        guard let baseURL = WDAAgentAPIClient.validateServerURL(serverBaseURL) else {
            phase = .failed(WDAAgentAPIError.invalidServerURL.localizedDescription)
            return
        }
        let code = enrollmentCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        phase = .enrolling
        lastError = nil
        do {
            let deviceUDIDs = WDADeviceInfo.provisionedUDIDs()
            print("[UDID-12] enroll 取到 deviceUDIDs=\(deviceUDIDs)")
#if !targetEnvironment(simulator)
            guard !deviceUDIDs.isEmpty else {
                print("[UDID-13] 真机 deviceUDIDs 为空，抛 missingDeviceUDID")
                throw WDAAgentAPIError.missingDeviceUDID
            }
#endif
            print("[WDAAgent] enroll deviceUdids=\(deviceUDIDs)")
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            let request = WDAEnrollRequest(
                enrollmentCode: code,
                installationId: WDADeviceInfo.installationID(),
                appVersion: version,
                osVersion: UIDevice.current.systemVersion,
                deviceModel: UIDevice.current.model,
                locale: Locale.current.identifier,
                platform: "ios",
                deviceUdids: deviceUDIDs
            )
            let response = try await WDAAgentAPIClient(baseURL: baseURL).enroll(request)
            guard !response.deviceToken.isEmpty, !response.config.networkSecret.isEmpty else {
                throw WDAAgentAPIError.missingSecrets
            }
            let config = WDAAgentConfig(
                schemaVersion: response.config.schemaVersion,
                configVersion: response.config.configVersion,
                deviceId: response.deviceId,
                networkName: response.config.networkName,
                networkCIDR: response.config.networkCIDR,
                iphoneIPv4: response.config.iphoneIPv4,
                relayHost: response.config.relayHost,
                relayPort: response.config.relayPort,
                serverBaseURL: baseURL.absoluteString,
                updatedAt: Date()
            )
            try config.validate()
            try WDAAgentKeychain.store(response.deviceToken, for: .deviceToken)
            try WDAAgentKeychain.store(response.config.networkSecret, for: .networkSecret)
            do {
                try WDAAgentStore.save(config)
            } catch {
                WDAAgentKeychain.delete(.deviceToken)
                WDAAgentKeychain.delete(.networkSecret)
                throw error
            }
            currentConfig = config
            phase = .enrolled
            connectionEnabled = true
            startServices()
        } catch {
            let message: String
            if let apiError = error as? WDAAgentAPIError, apiError == .httpStatus(401) {
                message = "注册码已使用或过期，请在平台重新生成后重试。"
            } else {
                message = "注册失败：\(error.localizedDescription)"
            }
            phase = .failed(message)
            lastError = message
        }
    }

    func stopConnection() {
        guard connectionEnabled else { return }
        reportStatus(.stopped)
        connectionEnabled = false
        stopHeartbeat()
        webSocket.disconnect()
    }

    func resumeConnection() {
        guard isEnrolled else { return }
        connectionEnabled = true
        startServices()
    }

    func refreshConfig() {
        Task { await applyRemoteConfig() }
    }

    func resetForReenrollment() {
        stopHeartbeat()
        webSocket.disconnect()
        WDAAgentKeychain.delete(.deviceToken)
        WDAAgentKeychain.delete(.networkSecret)
        WDAAgentStore.clear()
        currentConfig = nil
        enrollmentCode = ""
        connectionEnabled = false
        phase = .idle
        lastError = nil
    }

    private func startServices() {
        guard connectionEnabled, let config = currentConfig,
              let token = try? WDAAgentKeychain.read(.deviceToken) else { return }
        reportStatus(.online)
        startHeartbeat()
        // 三端串联 v6 §7.3：手机 AgentWebSocket 直连上报退役——设备/App 信息改由本地网关
        // 经 USB+WDA 采集后统一上报，手机零直连、零配置下发。默认关闭；对照回滚时改为 true。
        guard !Self.agentDirectReportingEnabled else {
            guard let url = AgentWSRoute.url(serverBaseURL: config.serverBaseURL) else { return }
            webSocket.connect(url: url, token: token)
            return
        }
    }

    /// 手机直连上报开关（退役后默认 false）。
    private static let agentDirectReportingEnabled = false

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.connectionEnabled else { return }
                self.reportStatus(.online)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func reportStatus(_ status: WDAAgentAppStatus) {
        Task {
            guard let config = currentConfig,
                  let baseURL = URL(string: config.serverBaseURL),
                  let token = try? WDAAgentKeychain.read(.deviceToken) else { return }
            let snapshot = WDAAgentStatus(appStatus: status, wdaUrl: wdaURL)
            do {
                try await WDAAgentAPIClient(baseURL: baseURL).reportStatus(token: token, status: snapshot)
            } catch let error as WDAAgentAPIError where error == .httpStatus(401) {
                resetForReenrollment()
                lastError = "设备已被平台移除，请重新注册。"
            } catch {
                // 瞬时网络失败由下一轮心跳或 WebSocket 重连恢复。
            }
        }
    }

    private func configureWebSocket() {
        webSocket.installationID = { WDADeviceInfo.installationID() }
        webSocket.configVersion = { [weak self] in self?.currentConfig?.configVersion ?? 0 }
        webSocket.wdaURL = { [weak self] in self?.wdaURL }
        webSocket.diagnosticPayload = { [weak self] in
            AgentWSPayload(
                configVersion: self?.currentConfig?.configVersion,
                appStatus: "online",
                wdaUrl: self?.wdaURL
            )
        }
        webSocket.onConfigChanged = { [weak self] _ in
            Task { await self?.applyRemoteConfig() }
        }
        webSocket.onAuthFailure = { [weak self] closeCode in
            guard let self else { return }
            if closeCode == .tokenInvalid {
                self.resetForReenrollment()
                self.lastError = "设备已被平台移除，请重新注册。"
            } else if closeCode == .deviceDisabled {
                self.connectionEnabled = false
                self.lastError = "设备已被平台禁用。"
            }
        }
        webSocket.onStateChanged = { [weak self] state in self?.socketState = state }
        webSocket.onMetricsChanged = { [weak self] latency, down, up, connectedAt in
            self?.latency = latency
            self?.downloadBytes = down
            self?.uploadBytes = up
            self?.connectedAt = connectedAt
        }
    }

    private func applyRemoteConfig() async {
        guard let config = currentConfig,
              let url = URL(string: config.serverBaseURL),
              let token = try? WDAAgentKeychain.read(.deviceToken) else { return }
        do {
            let newConfig = try await WDAAgentAPIClient(baseURL: url).fetchConfig(token: token)
            try newConfig.validate()
            try WDAAgentStore.save(newConfig)
            currentConfig = newConfig
            lastError = nil
            webSocket.sendStatus(payload: AgentWSPayload(
                configVersion: newConfig.configVersion,
                appStatus: "online",
                wdaUrl: wdaURL
            ))
        } catch let error as WDAAgentAPIError where error == .httpStatus(401) {
            resetForReenrollment()
            lastError = "设备已被平台移除，请重新注册。"
        } catch {
            lastError = "更新配置失败：\(error.localizedDescription)"
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connectionEnabled else { return }
                self.startServices()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopHeartbeat()
                self?.webSocket.suspend()
            }
        })
    }

    private func applyLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        if let serverURL = environment["WDA_SERVER_URL"], !serverURL.isEmpty {
            serverBaseURL = serverURL
        }
        if let code = environment["WDA_ENROLLMENT_CODE"], !code.isEmpty {
            enrollmentCode = code
        }
        if let index = arguments.firstIndex(of: "-server-url"), index + 1 < arguments.count {
            serverBaseURL = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "-enrollment-code"), index + 1 < arguments.count {
            enrollmentCode = arguments[index + 1]
        }
    }

    private static func webSocketURL(serverBaseURL: String) -> URL? {
        guard var components = URLComponents(string: serverBaseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path = "/api/ios-agent/v1/ws"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
