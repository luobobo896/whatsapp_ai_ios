import XCTest

final class TunnelLifecycleTests: XCTestCase {
    /// M0-A 后 XCFramework 已链接（scripts/build-easytier-ios.sh）。
    func testFFIIsLinked() {
        XCTAssertTrue(EasyTierRuntime.isLinked)
    }

    func testStatusSnapshotRoundTrip() throws {
        let snapshot = TunnelStatusSnapshot(
            phase: .connected,
            virtualIP: "10.168.1.5",
            peerCount: 1,
            lastErrorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TunnelStatusSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }
}
