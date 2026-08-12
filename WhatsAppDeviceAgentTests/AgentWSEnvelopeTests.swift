import XCTest
@testable import WhatsAppDeviceAgent

final class AgentWSEnvelopeTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
        let env = AgentWSEnvelope(
            type: .heartbeat,
            msgId: "inst:1",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: AgentWSPayload(foreground: true, vpnPhase: "stopped",
                                    peerCount: 0, appStatus: "online")
        )
        let data = try AgentWSEnvelope.jsonEncoder.encode(env)
        let decoded = try AgentWSEnvelope.jsonDecoder.decode(AgentWSEnvelope.self, from: data)
        XCTAssertEqual(decoded, env)
        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.type, .heartbeat)
        XCTAssertEqual(decoded.payload.foreground, true)
        XCTAssertEqual(decoded.payload.peerCount, 0)
    }

    func testPayloadOmitsNilOptionalFields() throws {
        let env = AgentWSEnvelope(
            type: .hello,
            msgId: "inst:1",
            sentAt: Date(),
            payload: AgentWSPayload(app: "WhatsAppDeviceAgent", configVersion: 3)
        )
        let data = try AgentWSEnvelope.jsonEncoder.encode(env)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["app"] as? String, "WhatsAppDeviceAgent")
        XCTAssertEqual(payload["configVersion"] as? Int, 3)
        XCTAssertNil(payload["wdaUrl"])
        XCTAssertNil(payload["requestId"])
    }

    func testDecodeMissingPayloadFields() throws {
        let json = #"{"v":1,"type":"server:ack","msgId":"s:1","sentAt":"2026-08-06T10:00:00Z","payload":{"ackedMsgId":"i:1"}}"#
        let env = try AgentWSEnvelope.jsonDecoder.decode(AgentWSEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.type, .ack)
        XCTAssertEqual(env.payload.ackedMsgId, "i:1")
        XCTAssertNil(env.payload.configVersion)
    }

    func testConfigChangedPayloadDecode() throws {
        let json = #"{"v":1,"type":"server:config_changed","msgId":"s:9","sentAt":"2026-08-06T10:00:00Z","payload":{"configVersion":5}}"#
        let env = try AgentWSEnvelope.jsonDecoder.decode(AgentWSEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.type, .configChanged)
        XCTAssertEqual(env.payload.configVersion, 5)
    }

    func testWSRouteURL() {
        XCTAssertEqual(AgentWSRoute.url(serverBaseURL: "https://hk.hsddns.com")?.absoluteString,
                       "wss://hk.hsddns.com/api/ios-agent/v1/ws")
        XCTAssertEqual(AgentWSRoute.url(serverBaseURL: "http://127.0.0.1:8790")?.absoluteString,
                       "ws://127.0.0.1:8790/api/ios-agent/v1/ws")
        XCTAssertNil(AgentWSRoute.url(serverBaseURL: "ftp://x"))
        XCTAssertNil(AgentWSRoute.url(serverBaseURL: "not a url"))
    }

    func testCloseCodeRawValues() {
        XCTAssertEqual(AgentWSCloseCode.tokenInvalid.rawValue, 4001)
        XCTAssertEqual(AgentWSCloseCode.replaced.rawValue, 4002)
        XCTAssertEqual(AgentWSCloseCode.deviceDisabled.rawValue, 4003)
        XCTAssertEqual(AgentWSCloseCode.protocolError.rawValue, 4004)
    }
}
