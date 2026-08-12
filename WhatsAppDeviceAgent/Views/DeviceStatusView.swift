import SwiftUI

/// 主界面（苹果风格）：在线状态卡片 + 右上角三个点菜单。
/// VPN/组网已移除，本页只展示 WDA 直连地址与设备信息，不再有 VPN 启停按钮。
struct DeviceStatusView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showReenrollConfirm = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusCard
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

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("连接状态", systemImage: "bolt.circle.fill")
                .font(.headline)
            Divider()
            row("状态", value: "在线", color: .green)
            if let config = model.currentConfig {
                row("设备 ID", value: model.deviceIDShort)
                row("WDA 地址", value: model.wdaUrl ?? "—")
                row("服务器", value: config.serverBaseURL)
                row("配置版本", value: "\(config.configVersion)")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
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
