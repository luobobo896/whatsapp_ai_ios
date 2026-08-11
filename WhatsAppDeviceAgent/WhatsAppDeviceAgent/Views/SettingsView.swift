import SwiftUI

/// 设置页（苹果风格分组列表）：设备信息、服务器与注册码（可改）、操作、关于。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var serverURLInput = ""
    @State private var enrollCodeInput = ""
    @State private var showApplyConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                if let config = model.currentConfig {
                    Section("设备") {
                        LabeledContent("设备 ID", value: model.deviceIDShort)
                        LabeledContent("服务器 ID", value: config.deviceId)
                        LabeledContent("虚拟 IP", value: config.iphoneIPv4)
                        LabeledContent("配置版本", value: "\(config.configVersion)")
                    }
                }
                Section("服务器与注册码") {
                    TextField("服务器地址", text: $serverURLInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("注册码", text: $enrollCodeInput)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    Button("保存并重新注册") {
                        showApplyConfirm = true
                    }
                    .disabled(serverURLInput.isEmpty || enrollCodeInput.isEmpty)
                }
                Section("操作") {
                    Button("重新注册", role: .destructive) {
                        model.resetForReenrollment()
                    }
                }
                Section("关于") {
                    LabeledContent("App 版本", value: appVersion)
                    LabeledContent("网络", value: "wa-ios")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                serverURLInput = model.currentConfig?.serverBaseURL ?? model.serverBaseURL
                enrollCodeInput = model.enrollmentCode
            }
            .confirmationDialog(
                "保存新配置后将清除当前设备配置并返回注册页，使用新服务器地址和注册码重新注册。",
                isPresented: $showApplyConfirm,
                titleVisibility: .visible
            ) {
                Button("保存并重新注册", role: .destructive) {
                    model.serverBaseURL = serverURLInput
                    model.enrollmentCode = enrollCodeInput
                    model.resetForReenrollment()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
