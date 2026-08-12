import Foundation
import Darwin

/// 设备网络信息（WDA 直连方案：平台通过局域网 IP 访问 WebDriverAgent :8100）。
enum DeviceNetwork {
    /// 返回当前活动网络的局域网 IPv4 地址（Wi-Fi en0 优先，其次蜂窝 pdp_ip0，最后任意 en* 接口），
    /// 排除 link-local（169.254.x.x）与回环。
    static func lanIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var en0IP: String?
        var cellularIP: String?
        var fallbackIP: String?
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "pdp_ip0" || name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr,
                                socklen_t(interface.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: host)
                    guard !ip.isEmpty, !ip.hasPrefix("169.254"), ip != "127.0.0.1" else { continue }
                    switch name {
                    case "en0":
                        if en0IP == nil { en0IP = ip }
                    case "pdp_ip0":
                        if cellularIP == nil { cellularIP = ip }
                    default:
                        if fallbackIP == nil { fallbackIP = ip }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        // Wi-Fi（en0）优先；无 Wi-Fi 时用蜂窝（pdp_ip0）；再退到任意 en* 接口。
        return en0IP ?? cellularIP ?? fallbackIP
    }
}
