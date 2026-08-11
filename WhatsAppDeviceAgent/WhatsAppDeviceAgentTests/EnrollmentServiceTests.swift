import XCTest
@testable import WhatsAppDeviceAgent

final class EnrollmentServiceTests: XCTestCase {
    func testValidateServerURLAcceptsHTTPS() {
        XCTAssertNotNil(AgentAPIClient.validateServerURL("https://vpn.us.example.net"))
    }

    func testValidateServerURLAcceptsHTTPLoopback() {
        XCTAssertNotNil(AgentAPIClient.validateServerURL("http://127.0.0.1:8790"))
        XCTAssertNotNil(AgentAPIClient.validateServerURL("http://localhost:8790"))
    }

    func testValidateServerURLRejectsPlainHTTPNonLoopback() {
        XCTAssertNil(AgentAPIClient.validateServerURL("http://vpn.us.example.net"))
    }

    func testValidateServerURLRejectsMalformed() {
        XCTAssertNil(AgentAPIClient.validateServerURL("not a url"))
        XCTAssertNil(AgentAPIClient.validateServerURL("ftp://example.net"))
    }
}
