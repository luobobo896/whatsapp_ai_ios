#if EASYTIER_IO_FD
import Darwin
import Foundation
import NetworkExtension

enum TunnelError: Error {
    case tunFileDescriptorUnavailable
    case tunFileDescriptorDupFailed(Int32)
}

/// 内部分发轨的 TUN fd 提取（设计 4.1 KVC 路径）。
/// App Store 轨禁止编译本文件（Release 走 PacketFlowBridge）。
enum TunnelFileDescriptor {
    /// 通过 packetFlow KVC 提取 fd 并 dup；失败必须让隧道启动失败（设计 4.1）。
    static func dup(from packetFlow: NEPacketTunnelFlow) throws -> Int32 {
        guard let number = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? NSNumber else {
            throw TunnelError.tunFileDescriptorUnavailable
        }
        let ownedFD = Darwin.dup(number.int32Value)
        guard ownedFD >= 0 else { throw TunnelError.tunFileDescriptorDupFailed(errno) }
        return ownedFD
    }
}
#endif
