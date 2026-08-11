#if EASYTIER_IO_FD
import Darwin
import Foundation
import NetworkExtension

// MARK: - <sys/kern_control.h> 补充定义
// Swift 无法直接 import 该 C 头，以下结构与常量与 SDK 头文件定义一致
// （WireGuard 通过 WireGuardKitC 模块引入，本项目保持单文件自包含）。

/// struct ctl_info { u_int32_t ctl_id; char ctl_name[MAX_KCTL_NAME=96]; }
private struct ctl_info {
    var ctl_id: UInt32 = 0
    var ctl_name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
    init() {
        ctl_name = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}

/// struct sockaddr_ctl（sc_len/sc_family/ss_sysaddr/sc_id/sc_unit/sc_reserved[5]）。
private struct sockaddr_ctl {
    var sc_len: UInt8 = 0
    var sc_family: UInt8 = 0
    var ss_sysaddr: UInt16 = 0
    var sc_id: UInt32 = 0
    var sc_unit: UInt32 = 0
    var sc_reserved: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
}

/// CTLIOCGINFO = _IOWR('N', 3, struct ctl_info)
/// = IOC_INOUT | ((sizeof(ctl_info) & IOCPARM_MASK) << 16) | ('N' << 8) | 3
private let ctlIocGinfo: UInt = {
    let iocInOut: UInt32 = 0xC0000000
    let iocparmMask: UInt32 = 0x1fff
    let group = UInt32(Character("N").asciiValue!)
    let num: UInt32 = 3
    let len = UInt32(MemoryLayout<ctl_info>.size) & iocparmMask
    return UInt(iocInOut | (len << 16) | (group << 8) | num)
}()

enum TunnelError: Error {
    case tunFileDescriptorUnavailable
    case tunFileDescriptorDupFailed(Int32)
}

/// 内部分发轨的 TUN fd 提取（设计 4.1）。
/// App Store 轨禁止编译本文件（Release 走 PacketFlowBridge）。
///
/// packetFlow 的 KVC 私有路径（`socket.fileDescriptor`）在 iOS 16+ 不可靠，可能返回 nil，
/// WireGuard 官方已弃用该写法。这里与 wireguard-apple 的 WireGuardAdapter 保持一致：
/// 遍历进程 fd，用 getpeername + CTLIOCGINFO 匹配 com.apple.net.utun_control 找到 TUN fd。
enum TunnelFileDescriptor {
    /// 找到当前 packetFlow 的 TUN fd 并 dup；失败必须让隧道启动失败（设计 4.1）。
    static func dup(from packetFlow: NEPacketTunnelFlow) throws -> Int32 {
        guard let fd = locateTunnelFileDescriptor() else {
            throw TunnelError.tunFileDescriptorUnavailable
        }
        let ownedFD = Darwin.dup(fd)
        guard ownedFD >= 0 else { throw TunnelError.tunFileDescriptorDupFailed(errno) }
        return ownedFD
    }

    /// 遍历 0...1024 的 fd，找出属于 com.apple.net.utun_control 的控制 socket。
    /// 实现与 wireguard-apple WireGuardAdapter.tunnelFileDescriptor 一致。
    private static func locateTunnelFileDescriptor() -> Int32? {
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, ctlIocGinfo, &ctlInfo)
                if ret != 0 {
                    continue
                }
            }
            if addr.sc_id == ctlInfo.ctl_id {
                return fd
            }
        }
        return nil
    }
}
#endif
