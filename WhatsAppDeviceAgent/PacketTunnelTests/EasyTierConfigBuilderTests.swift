import XCTest

final class EasyTierConfigBuilderTests: XCTestCase {
    private func makeInput() -> EasyTierConfigBuilder.Input {
        EasyTierConfigBuilder.Input(
            instanceName: "wa-ios-abcdefghijklmnopqrstuvwx",
            hostname: "iphone-abcdefghijklmnopqrstuvwx",
            ipv4: "10.168.1.5/16",
            relayHost: "us.hsddns.com",
            relayPort: 11010,
            networkName: "wa-ios",
            networkSecret: "secret-value",
            mtu: 1380
        )
    }

    func testBuildsTOMLMatchingDesignShape() throws {
        let toml = try EasyTierConfigBuilder.toml(makeInput())
        XCTAssertTrue(toml.contains("instance_name = \"wa-ios-abcdefghijklmnopqrstuvwx\""))
        XCTAssertTrue(toml.contains("ipv4 = \"10.168.1.5/16\""))
        XCTAssertTrue(toml.contains("[network_identity]"))
        XCTAssertTrue(toml.contains("network_secret = \"secret-value\""))
        XCTAssertTrue(toml.contains("uri = \"udp://us.hsddns.com:11010\""))
        XCTAssertTrue(toml.contains("uri = \"tcp://us.hsddns.com:11010\""))
        XCTAssertTrue(toml.contains("[flags]"))
        XCTAssertTrue(toml.contains("enable_ipv6 = false"))
        XCTAssertTrue(toml.contains("mtu = 1380"))
    }

    func testEscapesQuotesAndBackslashes() throws {
        var input = makeInput()
        input.networkSecret = "a\"b\\c"
        let toml = try EasyTierConfigBuilder.toml(input)
        XCTAssertTrue(toml.contains("network_secret = \"a\\\"b\\\\c\""))
    }

    func testRejectsInvalidPort() {
        var input = makeInput()
        input.relayPort = 70000
        XCTAssertThrowsError(try EasyTierConfigBuilder.toml(input)) { error in
            XCTAssertEqual(error as? EasyTierConfigBuilder.BuildError, .invalidRelayPort)
        }
    }

    func testRejectsInvalidIPv4() {
        var input = makeInput()
        input.ipv4 = "not-an-ip"
        XCTAssertThrowsError(try EasyTierConfigBuilder.toml(input)) { error in
            XCTAssertEqual(error as? EasyTierConfigBuilder.BuildError, .invalidIPv4("not-an-ip"))
        }
    }
}
