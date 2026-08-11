import XCTest
@testable import WhatsAppDeviceAgent

final class AgentConfigTests: XCTestCase {
    private func makeConfig() -> AgentConfig {
        AgentConfig(
            schemaVersion: 1,
            configVersion: 1,
            deviceId: "abcdefghijklmnopqrstuvwx",
            networkName: "wa-ios",
            networkCIDR: "10.168.0.0/16",
            iphoneIPv4: "10.168.1.5",
            relayHost: "us.hsddns.com",
            relayPort: 11010,
            serverBaseURL: "https://vpn.us.example.net",
            updatedAt: Date()
        )
    }

    func testValidateAcceptsValidConfig() {
        XCTAssertNoThrow(try makeConfig().validate())
    }

    func testValidateRejectsUnsupportedSchemaVersion() {
        var config = makeConfig()
        config.schemaVersion = 2
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AgentConfig.ValidationError, .unsupportedSchemaVersion(2))
        }
    }

    func testValidateRejectsInvalidIPv4() {
        var config = makeConfig()
        config.iphoneIPv4 = "10.168.1.999"
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AgentConfig.ValidationError, .invalidIPv4("10.168.1.999"))
        }
    }

    func testValidateRejectsInvalidRelayPort() {
        var config = makeConfig()
        config.relayPort = 0
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AgentConfig.ValidationError, .invalidRelayPort)
        }
    }

    func testValidateRejectsPlainHTTPNonLoopbackServer() {
        var config = makeConfig()
        config.serverBaseURL = "http://vpn.us.example.net"
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AgentConfig.ValidationError, .invalidServerBaseURL)
        }
    }

    func testEnrollResponseDecodesSampleFromDesign() throws {
        let json = """
        {
          "deviceId": "abcdefghijklmnopqrstuvwx",
          "deviceToken": "one-time-raw-token",
          "config": {
            "schemaVersion": 1,
            "configVersion": 1,
            "networkName": "wa-ios",
            "networkCIDR": "10.168.0.0/16",
            "iphoneIPv4": "10.168.1.5",
            "relayHost": "us.hsddns.com",
            "relayPort": 11010,
            "networkSecret": "one-time-network-secret"
          }
        }
        """
        let response = try JSONDecoder().decode(EnrollResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.deviceId, "abcdefghijklmnopqrstuvwx")
        XCTAssertEqual(response.config.relayPort, 11010)
        XCTAssertEqual(response.config.iphoneIPv4, "10.168.1.5")
    }
}
