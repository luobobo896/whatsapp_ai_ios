import XCTest
import NetworkExtension
@testable import WhatsAppDeviceAgent

final class VPNManagerTests: XCTestCase {
    @MainActor
    func testProviderProtocolFields() {
        let protocolConfig = VPNManager.providerProtocol(configVersion: 3)
        XCTAssertEqual(protocolConfig.providerBundleIdentifier, VPNManager.providerBundleID)
        XCTAssertEqual(protocolConfig.serverAddress, "EasyTier")
        let providerConfiguration = protocolConfig.providerConfiguration as? [String: Int]
        XCTAssertEqual(providerConfiguration?["schemaVersion"], 1)
        XCTAssertEqual(providerConfiguration?["configVersion"], 3)
    }
}
