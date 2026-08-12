import XCTest

/// 真实注册 UI 测试：模拟器运行 App，填入 HK 平台地址与租户注册码，走真实 enroll。
/// 注册码由 scheme TestAction 的 ENROLL_CODE 环境变量注入（app.launchEnvironment 可见）。
final class EnrollmentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRealEnrollmentToHK() throws {
        let app = XCUIApplication()
        let serverURL = EnrollmentConfig.serverURL
        let code = EnrollmentConfig.enrollmentCode
        // 未注入真实注册码（占位符）时跳过；由运行脚本生成租户注册码后替换再执行。
        if code.isEmpty || code.hasPrefix("__ENROLL") {
            throw XCTSkip("未注入注册码（EnrollmentConfig.swift 占位符），跳过真实注册")
        }

        app.launchArguments += ["-reset-enrollment", "-server-url", serverURL, "-enrollment-code", code]
        app.launch()

        // 等待注册按钮出现且可用（onAppear 已用 launchArguments 预填表单）。
        let registerButton = app.buttons["注册"]
        XCTAssertTrue(registerButton.waitForExistence(timeout: 10), "注册按钮未出现")
        let deadline = Date().addingTimeInterval(8)
        while !registerButton.isEnabled && Date() < deadline {
            usleep(200_000)
        }
        XCTAssertTrue(registerButton.isEnabled, "注册按钮不可用（表单未预填？）")
        registerButton.tap()

        // 注册成功后 RootView 切换到 DeviceStatusView（导航标题「设备状态」）。
        let statusTitle = app.navigationBars["设备"]
        if !statusTitle.waitForExistence(timeout: 40) {
            let labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            let fields = app.textFields.allElementsBoundByIndex.compactMap { $0.value as? String }
            XCTFail("注册未成功。界面: \(labels.joined(separator: " | ")) 输入: \(fields.joined(separator: " | "))")
        }
    }
}
