import Foundation
import Security

/// App 与 Extension 共用的共享 Keychain（设计 6.4）。
/// 只保存 device_token 与 network_secret，属性 AfterFirstUnlockThisDeviceOnly（设计 5.2）。
enum SharedKeychain {
    static let service = "com.whatsappai.deviceagent.shared"

    enum Key: String {
        case deviceToken = "agent.device_token"
        case networkSecret = "agent.network_secret"
        case installationID = "agent.installation_id"
    }

    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case itemNotFound
        case dataConversionFailed
    }

    static func store(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        // 已存在则更新，避免重复插入。
        let status = SecItemCopyMatching(
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: key.rawValue] as CFDictionary,
            nil)
        if status == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unexpectedStatus(update) }
        } else if status == errSecItemNotFound {
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.unexpectedStatus(add) }
        } else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func read(_ key: Key) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? KeychainError.itemNotFound : KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        return value
    }

    static func delete(_ key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
