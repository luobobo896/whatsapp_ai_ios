/// 真实注册 UI 测试的注入配置。
/// enrollmentCode 占位符 __ENROLL_CODE__ 由运行脚本（生成注册码后）替换，不提交真实注册码。
enum EnrollmentConfig {
    static let serverURL = "https://hk.hsddns.com"
    static let enrollmentCode = "__ENROLL_CODE__"
}
