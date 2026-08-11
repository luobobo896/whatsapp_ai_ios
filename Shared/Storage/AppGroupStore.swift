import Foundation

/// App Group 非秘密配置与 Extension 状态快照存储（设计 6.4）。
/// 写配置必须：写临时文件 -> fsync -> 原子 rename。
enum AppGroupStore {
    static let appGroupID = "group.com.whatsappai.deviceagent"
    static let configFileName = "agent-config.json"
    static let statusFileName = "tunnel-status.json"

    enum StoreError: Error {
        case containerUnavailable
        case encodeFailed
        case writeFailed
    }

    /// App Group 容器；开发构建（无签名/模拟器）回退到 Application Support，
    /// 保证本地开发可运行且不进入生产路径。
    static func containerURL() -> URL? {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) {
            return group
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("WhatsAppDeviceAgent", isDirectory: true)
    }

    static func saveConfig(_ config: AgentConfig) throws {
        try writeJSON(config, to: configFileName)
    }

    /// 清除本地配置（重新注册/退出时调用）。
    static func clear() {
        guard let container = containerURL() else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(configFileName))
    }

    static func loadConfig() throws -> AgentConfig? {
        try readJSON(AgentConfig.self, from: configFileName)
    }

    static func writeJSON<T: Encodable>(_ value: T, to fileName: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { throw StoreError.encodeFailed }
        try write(data, to: fileName)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from fileName: String) throws -> T? {
        let url = try fileURL(for: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private static func fileURL(for fileName: String) throws -> URL {
        guard let container = containerURL() else { throw StoreError.containerUnavailable }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container.appendingPathComponent(fileName, isDirectory: false)
    }

    /// 临时文件 -> fsync -> 原子替换（设计 6.4 要求）。
    private static func write(_ data: Data, to fileName: String) throws {
        let url = try fileURL(for: fileName)
        let tmpURL = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: [])
            let handle = try FileHandle(forWritingTo: tmpURL)
            try handle.synchronize()
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw StoreError.writeFailed
        }
    }
}
