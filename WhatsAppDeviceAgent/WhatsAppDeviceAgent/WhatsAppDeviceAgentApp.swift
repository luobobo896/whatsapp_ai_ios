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
            // 前台保持心跳在线；后台停止心跳（在线判定由 90s 超时窗口负责）。
            if phase == .active {
                model.startHeartbeat()
            } else {
                model.stopHeartbeat()
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
