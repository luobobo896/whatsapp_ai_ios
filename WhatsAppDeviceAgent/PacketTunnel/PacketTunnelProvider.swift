import NetworkExtension

enum PacketTunnelError: Error {
    case ffiNotConfigured
    case configUnavailable
    case secretUnavailable
    case invalidConfig
    case tunnelFdUnavailable
    case packetFlowNotImplemented
    case parseConfigFailed
    case runInstanceFailed
    case setTunFDFailed
    case connectionTimeout
    case instanceAlreadyStarted

    /// 写入状态快照 lastErrorCode 的稳定短码（设计 6.5 只保存错误码）。
    var errorCode: String {
        switch self {
        case .ffiNotConfigured: return "ffiNotConfigured"
        case .configUnavailable: return "configUnavailable"
        case .secretUnavailable: return "secretUnavailable"
        case .invalidConfig: return "invalidConfig"
        case .tunnelFdUnavailable: return "tunnelFdUnavailable"
        case .packetFlowNotImplemented: return "packetFlowNotImplemented"
        case .parseConfigFailed: return "parseConfigFailed"
        case .runInstanceFailed: return "runInstanceFailed"
        case .setTunFDFailed: return "setTunFDFailed"
        case .connectionTimeout: return "connectionTimeout"
        case .instanceAlreadyStarted: return "instanceAlreadyStarted"
        }
    }
}

/// 单个 instance 的运行信息（collect_network_infos JSON 解析，设计 6.5 只取需要的字段）。
private struct EasyTierInstanceStatus {
    var running: Bool
    var errorMsg: String?
    var peerCount: Int
    var virtualIP: String?
}

/// Packet Tunnel 生命周期（设计 6.5）。
/// fd 轨（Development/Ad Hoc，EASYTIER_IO_FD）固定顺序：
/// 串行队列状态检查 -> 读配置/secret 并校验 -> NE 设置（只路由 10.168.0.0/16） ->
/// setTunnelNetworkSettings -> dup TUN fd -> parse_config -> run_network_instance ->
/// set_tun_fd -> 每秒 collect_network_infos 等 running+peer（30s 超时）-> connected。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum RuntimeState {
        case stopped
        case starting
        case running
    }

    private let logger = RedactingLogger(category: "packet-tunnel")
    /// 专用串行队列：start/stop/report 全部在该队列串行执行，保证状态一致（设计 6.5）。
    private let queue = DispatchQueue(label: "com.whatsappai.deviceagent.packet-tunnel")
    private var state: RuntimeState = .stopped
    private var ownedFD: Int32 = -1
    private var instanceName: String?
    private var currentConfig: AgentConfig?
    private var statusTimer: Timer?
    private var pollTimer: DispatchSourceTimer?
    private var pollDeadline: Date?
    private var wakeDeadline: Date?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard EasyTierRuntime.isLinked else {
            TunnelStatusReporter.write(TunnelStatusSnapshot(phase: .ffiNotConfigured))
            completionHandler(PacketTunnelError.ffiNotConfigured)
            return
        }
        #if EASYTIER_IO_FD
        queue.async { [weak self] in
            self?.startTunnelFD(completionHandler: completionHandler)
        }
        #else
        // App Store 轨（packetFlow）尚未接入（M0-E 未做），明确失败不伪在线（设计 4.1）。
        TunnelStatusReporter.write(TunnelStatusSnapshot(phase: .recoveryRequired))
        completionHandler(PacketTunnelError.packetFlowNotImplemented)
        #endif
    }

    // MARK: - fd 轨启动（设计 6.5 步骤 1-9）

    #if EASYTIER_IO_FD
    private func startTunnelFD(completionHandler: @escaping (Error?) -> Void) {
        // 1. 串行队列检查状态必须为 stopped。
        guard state == .stopped else {
            completionHandler(PacketTunnelError.instanceAlreadyStarted)
            return
        }
        state = .starting

        // 2. 读 App Group 配置 + Keychain secret 并校验（设计 6.4：校验失败不启动）。
        guard let config = try? AppGroupStore.loadConfig() else {
            failStart(completionHandler, error: .configUnavailable)
            return
        }
        guard (try? config.validate()) != nil else {
            failStart(completionHandler, error: .invalidConfig)
            return
        }
        guard let secret = try? SharedKeychain.read(.networkSecret) else {
            failStart(completionHandler, error: .secretUnavailable)
            return
        }
        currentConfig = config
        TunnelStatusReporter.write(TunnelStatusSnapshot(phase: .connecting, virtualIP: config.iphoneIPv4))

        // 3. NE 设置：只包含共享网段 10.168.0.0/16 路由（设计 5.4），不接管默认互联网流量。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.168.0.1")
        let ipv4 = NEIPv4Settings(addresses: [config.iphoneIPv4], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.168.0.0",
                                           subnetMask: "255.255.0.0")]
        settings.ipv4Settings = ipv4
        settings.mtu = 1380

        // 4. setTunnelNetworkSettings 成功后提取并 dup TUN fd（设计 4.1 KVC 路径）。
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    self.failStart(completionHandler, error: .tunnelFdUnavailable)
                    return
                }
                do {
                    self.ownedFD = try TunnelFileDescriptor.dup(from: self.packetFlow)
                } catch {
                    self.failStart(completionHandler, error: .tunnelFdUnavailable)
                    return
                }

                // 5-7. 生成 TOML -> parse_config -> run_network_instance -> set_tun_fd。
                let input = EasyTierConfigBuilder.Input(
                    instanceName: "wa-ios-\(config.deviceId)",
                    hostname: "iphone-\(config.deviceId)",
                    ipv4: "\(config.iphoneIPv4)/16",
                    relayHost: config.relayHost,
                    relayPort: config.relayPort,
                    networkName: config.networkName,
                    networkSecret: secret,
                    mtu: 1380
                )
                guard let toml = try? EasyTierConfigBuilder.toml(input) else {
                    self.failStart(completionHandler, error: .invalidConfig)
                    return
                }
                self.instanceName = input.instanceName
                guard case .success = EasyTierBridge.parseConfig(toml) else {
                    self.failStart(completionHandler, error: .parseConfigFailed)
                    return
                }
                guard case .success = EasyTierBridge.runNetworkInstance(toml) else {
                    self.failStart(completionHandler, error: .runInstanceFailed)
                    return
                }
                guard case .success = EasyTierBridge.setTunFD(instanceName: input.instanceName,
                                                              fd: self.ownedFD) else {
                    // 设计 6.5：set_tun_fd 失败 -> retain(NULL, 0) 再关闭 fd。
                    self.teardown()
                    self.failStart(completionHandler, error: .setTunFDFailed)
                    return
                }

                // 8. 每秒 collect_network_infos，最多等待 30 秒，等 running 且无 error 且至少一个 peer。
                self.waitForRunning(config: config, completionHandler: completionHandler)
            }
        }
    }

    private func waitForRunning(config: AgentConfig,
                                completionHandler: @escaping (Error?) -> Void) {
        guard let instanceName else {
            failStart(completionHandler, error: .runInstanceFailed)
            return
        }
        pollDeadline = Date().addingTimeInterval(30)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let info = self.collectInstanceInfo(instanceName)
            if let info, info.running, info.errorMsg == nil, info.peerCount > 0 {
                timer.cancel()
                self.pollTimer = nil
                self.state = .running
                self.wakeDeadline = nil
                self.startStatusTimerIfNeeded()
                TunnelStatusReporter.write(TunnelStatusSnapshot(
                    phase: .connected,
                    virtualIP: info.virtualIP ?? config.iphoneIPv4,
                    peerCount: info.peerCount))
                completionHandler(nil)
            } else if let deadline = self.pollDeadline, Date() >= deadline {
                // 超时：完整 stop 并返回错误（设计 6.5 步骤 8/9）。
                timer.cancel()
                self.pollTimer = nil
                let lastError = info?.errorMsg ?? PacketTunnelError.connectionTimeout.errorCode
                self.teardown()
                TunnelStatusReporter.write(TunnelStatusSnapshot(
                    phase: .stopped,
                    virtualIP: config.iphoneIPv4,
                    lastErrorCode: lastError))
                completionHandler(PacketTunnelError.connectionTimeout)
            }
        }
        timer.resume()
        pollTimer = timer
    }

    /// 解析 collect_network_infos 中本 instance 的运行 JSON（设计 6.5 只保存 peer 数/running/错误码/时间）。
    private func collectInstanceInfo(_ instanceName: String) -> EasyTierInstanceStatus? {
        guard case .success(let infos) = EasyTierBridge.collectNetworkInfos(maxCount: 8),
              let json = infos[instanceName],
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let running = (obj["running"] as? Bool) ?? false
        let errorMsg = obj["error_msg"] as? String
        let peerCount = (obj["peers"] as? [Any])?.count ?? 0
        var virtualIP: String?
        if let node = obj["my_node_info"] as? [String: Any],
           let vip = node["virtual_ipv4"] as? String {
            virtualIP = vip
        }
        return EasyTierInstanceStatus(running: running,
                                      errorMsg: errorMsg,
                                      peerCount: peerCount,
                                      virtualIP: virtualIP)
    }
    #endif

    // MARK: - 停止 / 休眠 / 唤醒（设计 6.5）

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        #if EASYTIER_IO_FD
        queue.async { [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            // 1. 停止状态 timer。
            self.stopStatusTimer()
            // 2. set_tun_fd(instanceName, -1) 清理移动 TUN。
            if let name = self.instanceName {
                _ = EasyTierBridge.setTunFD(instanceName: name, fd: -1)
                // 3. retain_network_instance(NULL, 0) 删除全部 instance。
                _ = EasyTierBridge.retainNetworkInstances([])
                self.instanceName = nil
            }
            // 4. close(ownedFD)，置为 -1 保证只关闭一次。
            if self.ownedFD >= 0 {
                Darwin.close(self.ownedFD)
                self.ownedFD = -1
            }
            self.state = .stopped
            self.pollTimer?.cancel()
            self.pollTimer = nil
            // 5. App Group 状态写 stopped。
            TunnelStatusReporter.write(TunnelStatusSnapshot(phase: .stopped))
            completionHandler()
        }
        #else
        TunnelStatusReporter.write(TunnelStatusSnapshot(phase: .stopped))
        completionHandler()
        #endif
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        // 只停止统计 timer，不销毁 instance（设计 6.5）。
        queue.async { [weak self] in
            self?.stopStatusTimer()
            completionHandler()
        }
    }

    override func wake() {
        // 恢复 timer；30 秒仍无 peer 时 cancelTunnelWithError 触发系统重连（设计 6.5）。
        queue.async { [weak self] in
            guard let self else { return }
            self.wakeDeadline = Date().addingTimeInterval(30)
            self.startStatusTimerIfNeeded()
            self.collectAndReport()
        }
    }

    // MARK: - 状态采集（设计 6.5 步骤 10：每 15 秒）

    private func collectAndReport() {
        guard let instanceName, let config = currentConfig else { return }
        let info = collectInstanceInfo(instanceName)
        let running = info?.running ?? false
        TunnelStatusReporter.write(TunnelStatusSnapshot(
            phase: running ? .connected : .recoveryRequired,
            virtualIP: info?.virtualIP ?? config.iphoneIPv4,
            peerCount: info?.peerCount ?? 0,
            lastErrorCode: info?.errorMsg))
        // wake 后 30 秒仍无 peer -> 系统重连。
        if let deadline = wakeDeadline, !running, Date() >= deadline {
            wakeDeadline = nil
            DispatchQueue.main.async { [weak self] in
                self?.cancelTunnelWithError(PacketTunnelError.connectionTimeout)
            }
        }
    }

    private func startStatusTimerIfNeeded() {
        guard statusTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.queue.async { self?.collectAndReport() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// 失败统一清理：销毁 instance、关闭 fd、写 stopped 状态后回调错误（设计 6.5）。
    private func failStart(_ completion: @escaping (Error?) -> Void, error: PacketTunnelError) {
        teardown()
        TunnelStatusReporter.write(TunnelStatusSnapshot(
            phase: .stopped,
            virtualIP: currentConfig?.iphoneIPv4,
            lastErrorCode: error.errorCode))
        completion(error)
    }

    private func teardown() {
        if let instanceName {
            _ = EasyTierBridge.setTunFD(instanceName: instanceName, fd: -1)
            _ = EasyTierBridge.retainNetworkInstances([])
            self.instanceName = nil
        }
        if ownedFD >= 0 {
            Darwin.close(ownedFD)
            ownedFD = -1
        }
        stopStatusTimer()
        state = .stopped
    }
}
