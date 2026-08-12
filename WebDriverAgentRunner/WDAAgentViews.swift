import SwiftUI
import UIKit

@MainActor
struct WDARegistrationPageView: View {
    @ObservedObject private var model = WDAAgentModel.shared
    let onScan: () -> Void
    let onHome: () -> Void
    let onRegistered: () -> Void

    @State private var didNavigate = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("平台地址")) {
                    TextField("https://hk.hsddns.com", text: $model.serverBaseURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("serverUrlField")
                }

                Section(header: Text("一次性注册码")) {
                    TextField("9C4K-7Q2M-P8RX-H5TW", text: $model.enrollmentCode)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("enrollmentCodeField")

                    Button(action: onScan) {
                        Label("扫码注册", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("backToScanButton")
                }

                if case .failed(let message) = model.phase {
                    Section {
                        Text(message)
                            .foregroundColor(.red)
                            .accessibilityIdentifier("registrationStatus")
                    }
                }

                Section {
                    Button {
                        Task { await model.enroll() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.phase == .enrolling {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("正在注册")
                            } else {
                                Text("注册")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!isInputValid || model.phase == .enrolling)
                    .accessibilityIdentifier("registerButton")
                }
            }
            .navigationTitle("注册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onHome) {
                        Image(systemName: "house")
                    }
                    .accessibilityLabel("首页")
                    .accessibilityIdentifier("homeButton")
                }
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: model.phase) { phase in
            guard phase == .enrolled, !didNavigate else { return }
            didNavigate = true
            onRegistered()
        }
        .onAppear {
            guard ProcessInfo.processInfo.environment["WDA_AUTO_ENROLL"] == "1",
                  model.phase != .enrolling,
                  model.phase != .enrolled else { return }
            Task { await model.enroll() }
        }
    }

    private var isInputValid: Bool {
        !model.serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.enrollmentCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
struct WDADeviceStatusPageView: View {
    @ObservedObject private var model = WDAAgentModel.shared
    let onReenroll: () -> Void

    @State private var showReenrollConfirmation = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        statusCard
                        if let error = model.lastError, !error.isEmpty {
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("重新注册") {
                            showReenrollConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color(white: 0.10))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("设备操作")
                    .accessibilityIdentifier("deviceMenuButton")
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .onAppear {
            // 默认进来就是连接中：进入设备状态页自动建立连接（无需点启动）。
            model.resumeConnection()
        }
        .onChange(of: model.phase) { phase in
            guard phase == .idle else { return }
            onReenroll()
        }
        .confirmationDialog("重新注册会清除当前设备凭据", isPresented: $showReenrollConfirmation) {
            Button("重新注册", role: .destructive) {
                model.resetForReenrollment()
            }
            Button("取消", role: .cancel) {}
        }
    }


    private var statusCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.title2)
                    Text("连接状态")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                .padding(.bottom, 16)

                Divider()
                    .overlay(Color.white.opacity(0.12))
                    .padding(.bottom, 12)

                statusRow("状态", value: model.connectionText, valueColor: statusColor)
                statusRow("服务器", value: model.serverAddress)
                statusRow("IP 地址", value: model.wdaURL ?? "--")
                statusRow("延迟", value: latencyText)
                statusRow("下行", value: Self.bytesText(model.downloadBytes))
                statusRow("上行", value: Self.bytesText(model.uploadBytes))
                statusRow("连接时间", value: Self.startTimeText(model.connectedAt))
                statusRow("已连接", value: Self.elapsedText(from: model.connectedAt, to: context.date))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(Color(red: 0.10, green: 0.10, blue: 0.11))
            .cornerRadius(8)
        }
        .accessibilityIdentifier("connectionStatusCard")
    }

    private var statusColor: Color {
        model.socketState == .connected ? Color(red: 0.12, green: 0.82, blue: 0.34) : .secondary
    }

    private var latencyText: String {
        guard let latency = model.latency else { return "--" }
        return "\(max(1, Int((latency * 1_000).rounded()))) ms"
    }

    private func statusRow(_ label: String, value: String, valueColor: Color = .white) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .font(.system(size: 17))
        .frame(minHeight: 35)
    }

    private static func bytesText(_ bytes: Int64) -> String {
        if bytes < 1_024 { return "0 KB" }
        if bytes < 1_048_576 { return "\(bytes / 1_024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static func startTimeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func elapsedText(from start: Date?, to now: Date) -> String {
        guard let start else { return "00:00:00" }
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }
}

@_cdecl("WDAAgentApplyEnrollmentCode")
@MainActor
public func WDAAgentApplyEnrollmentCode(_ value: NSString) {
    WDAAgentModel.shared.applyScannedPayload(value as String)
}

@_cdecl("WDAAgentRestoreEnrollment")
@MainActor
public func WDAAgentRestoreEnrollment() -> Bool {
    WDAAgentModel.shared.restoreIfNeeded()
}

@_cdecl("WDAAgentHasEnrollmentPrefill")
@MainActor
public func WDAAgentHasEnrollmentPrefill() -> Bool {
    !WDAAgentModel.shared.enrollmentCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

@_cdecl("WDARegistrationHostMakeViewController")
@MainActor
public func WDARegistrationHostMakeViewController(
    onScan: @escaping @convention(block) () -> Void,
    onHome: @escaping @convention(block) () -> Void,
    onRegistered: @escaping @convention(block) () -> Void
) -> UIViewController {
    let root = WDARegistrationPageView(
        onScan: onScan,
        onHome: onHome,
        onRegistered: onRegistered
    )
    let hosting = UIHostingController(rootView: root)
    hosting.view.backgroundColor = .systemGroupedBackground
    return hosting
}

@_cdecl("WDADeviceStatusHostMakeViewController")
@MainActor
public func WDADeviceStatusHostMakeViewController(
    onReenroll: @escaping @convention(block) () -> Void
) -> UIViewController {
    let hosting = UIHostingController(rootView: WDADeviceStatusPageView(onReenroll: onReenroll))
    hosting.view.backgroundColor = .black
    return hosting
}
