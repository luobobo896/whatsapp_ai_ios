import Foundation

/// 从开发签名包的 embedded.mobileprovision 读取 UDID 列表（设计 7.1 扩展）。
/// iOS 自 7.0 起不允许普通 App 读取硬件 UDID（无公共 API），
/// 开发/Ad Hoc 签名包内的 provisioning profile 是 App 唯一能拿到真实 UDID 的途径。
/// 注意：profile 可能包含多台设备（ProvisionedDevices），App 无法据此自证是哪一台。
enum DeviceUdid {
    /// 返回 embedded.mobileprovision 的 ProvisionedDevices（UDID 列表）。
    static func provisionedUdids() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let plistData = extractPlistData(from: data),
              let plist = try? PropertyListSerialization.propertyList(from: plistData,
                                                                      options: [],
                                                                      format: nil) as? [String: Any],
              let devices = plist["ProvisionedDevices"] as? [String] else {
            return []
        }
        return devices
    }

    /// mobileprovision 是 CMS 签名数据，明文 plist 嵌在 <?xml ... </plist> 之间（经典提取法）。
    private static func extractPlistData(from data: Data) -> Data? {
        guard let str = String(data: data, encoding: .isoLatin1) else { return nil }
        let startMarker = "<?xml"
        let endMarker = "</plist>"
        guard let start = str.range(of: startMarker),
              let end = str.range(of: endMarker, range: start.upperBound..<str.endIndex) else { return nil }
        let xml = str[start.lowerBound..<end.upperBound]
        return xml.data(using: .isoLatin1)
    }
}
