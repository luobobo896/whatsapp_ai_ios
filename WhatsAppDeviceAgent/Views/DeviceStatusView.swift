import SwiftUI

/// 主界面（苹果风格）：中央大电源按钮启停 VPN + 连接状态卡片 + 右上角三个点菜单。
struct DeviceStatusView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showReenrollConfirm = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    powerButton
                    if let config = model.currentConfig {
                        connectionCard(config)
                    }
                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showSettings = true
                        } label: {
                            Label("修改配置", systemImage: "gearshape")
                        }
                        Button(role: .destructive) {
                            showReenrollConfirm = true
                        } label: {
                            Label("重新注册", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(model)
            }
            .confirmationDialog(
                "重新注册将清除当前设备配置并返回注册页，确定继续？",
                isPresented: $showReenrollConfirm,
                titleVisibility: .visible
            ) {
                Button("重新注册", role: .destructive) {
                    model.resetForReenrollment()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 大电源按钮（启动/停止）

    private var powerButton: some View {
        Button {
            if model.vpnState == .idle {
                model.startVPN()
            } else {
                model.stopVPN()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(buttonColor)
                    .frame(width: 180, height: 180)
                    .shadow(color: buttonColor.opacity(0.4), radius: 16, y: 8)
                VStack(spacing: 10) {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 46))
                        .foregroundColor(.white)
                    Text(buttonLabel)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.isConfigReady)
        .opacity(model.isConfigReady ? 1 : 0.4)
    }

    private var buttonColor: Color {
        switch model.vpnState {
        case .idle: return .accentColor
        case .connecting: return .blue
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var buttonIcon: String {
        switch model.vpnState {
        case .idle: return "power"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "stop.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var buttonLabel: String {
        switch model.vpnState {
        case .idle: return "启动"
        case .connecting: return "连接中"
        case .connected: return "停止"
        case .failed: return "重试"
        }
    }

    // MARK: - 连接状态卡片

    private func connectionCard(_ config: AgentConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("连接状态", systemImage: "bolt.circle.fill")
                .font(.headline)
            Divider()
            row("状态", value: statusText, color: statusColor)
            row("服务器", value: "\(config.relayHost):\(config.relayPort)")
            row("虚拟 IP", value: config.iphoneIPv4)
            row("延迟", value: model.serverLatency ?? "—")
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var statusText: String {
        switch model.vpnState {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .failed: return "连接失败"
        }
    }

    private var statusColor: Color {
        switch model.vpnState {
        case .idle: return .secondary
        case .connecting: return .blue
        case .connected: return .green
        case .failed: return .red
        }
    }

    private func row(_ title: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(color)
        }
        .font(.subheadline)
    }
}
