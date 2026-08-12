import Foundation
import os

/// 日志脱敏（设计 15：token、secret、完整 phone/content/source/screenshot 不得入日志）。
/// 所有日志输出必须经过 redact。
struct RedactingLogger {
    let subsystem: String
    let category: String
    private let logger: Logger

    init(subsystem: String = "com.whatsappai.deviceagent",
         category: String = "default") {
        self.subsystem = subsystem
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    /// 敏感字段值统一替换为 <redacted>。
    static func redact(_ string: String) -> String {
        var result = string
        for pattern in Self.sensitivePatterns {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1<redacted>"
            )
        }
        return result
    }

    func debug(_ message: String) { logger.debug("\(Self.redact(message), privacy: .public)") }
    func info(_ message: String) { logger.info("\(Self.redact(message), privacy: .public)") }
    func error(_ message: String) { logger.error("\(Self.redact(message), privacy: .public)") }

    private static let sensitivePatterns: [NSRegularExpression] = [
        // JSON 键值：deviceToken / networkSecret / enrollmentCode / device_token / network_secret 等
        try! NSRegularExpression(
            pattern: #"("?(?:deviceToken|networkSecret|enrollmentCode|device_token|network_secret|token|secret)"?\s*[:=]\s*")([^",\s}]+)"#),
        // 查询/表单形式：key=value
        try! NSRegularExpression(
            pattern: #"((?:device_token|network_secret|token|secret|code)=)[^\s&"]+"#),
        // Authorization Bearer
        try! NSRegularExpression(
            pattern: #"((?:Authorization|authorization)\s*[:=]\s*Bearer\s+)[A-Za-z0-9._-]+"#),
    ]
}
