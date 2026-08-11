import SwiftUI

/// 注册引导页（苹果风格）：未注册时先提示扫码注册，也可手动输入注册码。
/// 扫码是一个大按钮；手动输入为次要入口。
struct EnrollmentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showManualForm = false
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            if showManualForm {
                manualForm
            } else {
                onboarding
            }
        }
    }

    // MARK: - 首次引导：扫码是大按钮

    private var onboarding: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 76))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("注册你的设备")
                    .font(.largeTitle.bold())
                Text("扫描平台生成的二维码完成注册")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                scanning = true
            } label: {
                Label("扫码注册", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("手动输入注册码") {
                showManualForm = true
            }
            .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 32)
        .navigationBarHidden(true)
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                model.enrollmentCode = code
                showManualForm = true
            }
        }
        .onAppear {
            // UI 测试/自动化预填（-server-url / -enrollment-code）；预填后直接进入手动表单。
            let args = ProcessInfo.processInfo.arguments
            if let idx = args.firstIndex(of: "-server-url"), idx + 1 < args.count {
                model.serverBaseURL = args[idx + 1]
            }
            if let idx = args.firstIndex(of: "-enrollment-code"), idx + 1 < args.count {
                model.enrollmentCode = args[idx + 1]
                showManualForm = true
            }
        }
    }

    // MARK: - 手动注册表单

    private var manualForm: some View {
        Form {
            Section("平台地址") {
                TextField("https://hk.hsddns.com", text: $model.serverBaseURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section("一次性注册码") {
                TextField("9C4K-7Q2M-P8RX-H5TW", text: $model.enrollmentCode)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                Button {
                    scanning = true
                } label: {
                    Label("扫码注册", systemImage: "qrcode.viewfinder")
                }
            }
            if case .failed(let message) = model.phase {
                Section {
                    Text(message).foregroundColor(.red)
                }
            }
            Section {
                Button("注册并启用 VPN") {
                    Task {
                        await model.enroll()
                    }
                }
                .disabled(model.phase == .enrolling || !isInputValid)
            }
        }
        .navigationTitle("注册")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                model.enrollmentCode = code
            }
        }
    }

    private var isInputValid: Bool {
        !model.serverBaseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
            !model.enrollmentCode.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
