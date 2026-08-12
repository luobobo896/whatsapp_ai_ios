import SwiftUI

@main
struct WhatsAppDeviceAgentApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            // 前台保持心跳在线并连接平台 WSS（§6.8）；后台停心跳、发 app:suspended 后断 WSS。
            if phase == .active {
                model.startHeartbeat()
                model.startWebSocket()
            } else {
                model.stopHeartbeat()
                model.suspendWebSocket()
            }
        }
    }
}

/// 仅两个实际页面（设计 6.7）：未注册 -> EnrollmentView，已注册 -> DeviceStatusView。
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isEnrolled {
                DeviceStatusView()
            } else {
                EnrollmentView()
            }
        }
        .onAppear {
            // UI 测试确定性：-reset-enrollment 启动参数先清空本地注册态，
            // 保证每次测试都从注册引导页开始（避免残留 Keychain/App Group）。
            if ProcessInfo.processInfo.arguments.contains("-reset-enrollment") {
                model.resetForReenrollment()
            }
            model.restoreIfNeeded()
        }
    }
}
