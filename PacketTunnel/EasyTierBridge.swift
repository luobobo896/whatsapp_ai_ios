import Foundation

/// Swift 对 EasyTier C ABI 的唯一入口（设计 6.1）。
/// 基础 ABI 与 public packetFlow bridge ABI 声明见 Vendor/EasyTier/include/easytier_ffi.h
/// （由 PacketTunnel target 的 SWIFT_OBJC_BRIDGING_HEADER 导入）。
///
/// 开发前置准备阶段 xcframework 尚未链接（isLinked == false），所有对 C 符号的调用
/// 由 `#if EASYTIER_FFI_LINKED` 保护，避免产生未定义符号。
enum EasyTierRuntime {
    /// FFI 是否已链接。M0-A 已通过 `scripts/build-easytier-ios.sh` 产出并链接 XCFramework。
    static let isLinked = true
}

enum EasyTierFFIError: Error, Equatable {
    case message(String)
}

enum EasyTierIOError {
    static let ok: Int32 = 0
    static let eagain: Int32 = -11
    static let einval: Int32 = -22
    static let enoent: Int32 = -2
}

enum EasyTierBridge {
    /// parse_config：校验并解析 TOML 配置。
    static func parseConfig(_ config: String) -> Result<Int32, EasyTierFFIError> {
        #if EASYTIER_FFI_LINKED
        let result = parse_config(config)
        return result == EasyTierIOError.ok ? .success(result) : .failure(EasyTierFFIError.message(currentErrorMessage()))
        #else
        return .failure(EasyTierFFIError.message("EasyTier FFI 未链接（开发前置准备阶段）"))
        #endif
    }

    /// run_network_instance：启动网络实例。
    static func runNetworkInstance(_ config: String) -> Result<Int32, EasyTierFFIError> {
        #if EASYTIER_FFI_LINKED
        let result = run_network_instance(config)
        return result == EasyTierIOError.ok ? .success(result) : .failure(EasyTierFFIError.message(currentErrorMessage()))
        #else
        return .failure(EasyTierFFIError.message("EasyTier FFI 未链接（开发前置准备阶段）"))
        #endif
    }

    /// set_tun_fd：绑定 TUN fd（内部分发轨）。
    static func setTunFD(instanceName: String, fd: Int32) -> Result<Int32, EasyTierFFIError> {
        #if EASYTIER_FFI_LINKED
        let result = set_tun_fd(instanceName, fd)
        return result == EasyTierIOError.ok ? .success(result) : .failure(EasyTierFFIError.message(currentErrorMessage()))
        #else
        return .failure(EasyTierFFIError.message("EasyTier FFI 未链接（开发前置准备阶段）"))
        #endif
    }

    /// retain_network_instance：保留（或清空）网络实例。
    static func retainNetworkInstances(_ names: [String]) -> Result<Int32, EasyTierFFIError> {
        #if EASYTIER_FFI_LINKED
        let cNames: [UnsafePointer<CChar>?] = names.map { strdup($0).map { UnsafePointer($0) } }
        defer { cNames.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let result = retain_network_instance(cNames, names.count)
        return result == EasyTierIOError.ok ? .success(result) : .failure(EasyTierFFIError.message(currentErrorMessage()))
        #else
        return .failure(EasyTierFFIError.message("EasyTier FFI 未链接（开发前置准备阶段）"))
        #endif
    }

    /// collect_network_infos：采集运行信息；返回的 key/value 由调用方 free（设计 6.2）。
    static func collectNetworkInfos(maxCount: Int) -> Result<[String: String], EasyTierFFIError> {
        #if EASYTIER_FFI_LINKED
        var infos = [ETKeyValuePair](repeating: ETKeyValuePair(), count: maxCount)
        // collect_network_infos 返回写入的实例条数（>=0 成功，-1 失败），不是 0/非0 成功码。
        let result = collect_network_infos(&infos, maxCount)
        guard result >= 0 else { return .failure(EasyTierFFIError.message(currentErrorMessage())) }
        let count = Int(result)
        var dict: [String: String] = [:]
        for index in 0..<count {
            guard let key = infos[index].key, let value = infos[index].value else { break }
            dict[String(cString: key)] = String(cString: value)
        }
        // 复制后必须 free 所有由 FFI 分配的字符串（设计 6.2）。
        for index in 0..<count {
            if let key = infos[index].key { free_string(key) }
            if let value = infos[index].value { free_string(value) }
        }
        return .success(dict)
        #else
        return .failure(EasyTierFFIError.message("EasyTier FFI 未链接（开发前置准备阶段）"))
        #endif
    }

    #if EASYTIER_FFI_LINKED
    private static func currentErrorMessage() -> String {
        var out: UnsafePointer<CChar>?
        get_error_msg(&out)
        guard let out else { return "unknown EasyTier error" }
        defer { free_string(out) }
        return String(cString: out)
    }
    #endif
}
