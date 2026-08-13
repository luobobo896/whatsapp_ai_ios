/**
 * 首页（注册引导页）：从 whatsapp_ai_ios 的 WhatsAppDeviceAgent/Views/EnrollmentView.swift 挪入。
 * 样式与行为保持一致：扫码注册（大按钮）+ 手动输入注册码（次入口）。
 */

import SwiftUI
import UIKit

/// 首页内容（对应 whatsapp_ai_ios EnrollmentView.onboarding）。
struct WDAHomePageView: View {
    var onScan: () -> Void
    var onManualInput: () -> Void

    var body: some View {
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
            Button(action: onScan) {
                Label("扫码注册", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .accessibilityIdentifier("scanRegistrationButton")
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("手动输入注册码", action: onManualInput)
                .font(.subheadline)
                .accessibilityIdentifier("manualRegistrationButton")
            Spacer()
        }
        .padding(.horizontal, 32)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

/// 供 ObjC（UITestingUITests）以 C 函数形式承载 SwiftUI 首页（避免依赖 -Swift.h 生成）。
@_cdecl("WDAHomePageHostMakeViewController")
public func WDAHomePageHostMakeViewController(
    onScan: @escaping @convention(block) () -> Void,
    onManualInput: @escaping @convention(block) () -> Void
) -> UIViewController {
    let hosting = UIHostingController(rootView: WDAHomePageView(onScan: onScan, onManualInput: onManualInput))
    hosting.view.backgroundColor = .systemBackground
    return hosting
}
