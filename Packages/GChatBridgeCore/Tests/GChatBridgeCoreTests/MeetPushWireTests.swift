import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetPushWireTests {
    private func ring(_ extra: Data = Data()) -> Data {
        MeetProto.bytes(
            1,
            MeetProto.string(1, "ring-secret") + MeetProto.string(2, "abc-defg-hij")
                + MeetProto.number(4, 1) + MeetProto.string(7, "context-secret")
                + MeetProto.string(8, "receiver-secret") + MeetProto.string(11, "dm/known") + MeetProto
                .number(
                    12,
                    1
                ) + extra
        )
    }

    private func push(_ data: Data, sequence: String = "1") -> PBLiteValue {
        let change: PBLiteValue = [nil, .string(data.base64EncodedString()), "42", nil, nil, [[["object"]]]]
        let response: PBLiteValue = [[[.string(sequence), [nil, [[change]]]]]]
        return [response]
    }

    @Test func decodesOnlyTheRegisteredWatchAndRequiresObjectAndVersion() throws {
        let events = try MeetPushWire.events(in: push(ring()))
        #expect(events.count == 1)
        guard case let .ring(value) = events.first else { Issue.record("Missing ring"); return }
        #expect(value.id == "ring-secret")
        #expect(value.callIdentifier == "abc-defg-hij")
        #expect(value.dmID == "dm/known")
        #expect(value.notificationContext == "context-secret")
        #expect(value.receiverClientID == "receiver-secret")
        #expect(try MeetPushWire.events(in: push(ring(), sequence: "2")).isEmpty)
        let noObject: PBLiteValue = [[["1", [nil, [[[nil, .string(ring().base64EncodedString()), "42"]]]]]]]
        #expect(try MeetPushWire.events(in: [noObject]).isEmpty)
    }

    @Test func ringEndNeedsNoCallerProfile() throws {
        let data = MeetProto.bytes(2, MeetProto.string(1, "ring-secret") + MeetProto.number(2, 3))
        guard case let .ended(id, reason) = try MeetPushWire.payload(data) else {
            Issue.record("Missing end"); return
        }
        #expect(id == "ring-secret")
        #expect(reason == 3)
    }

    @Test func refusesDuplicateVariantsFieldsAndMalformedBytes() {
        for data in [ring() + ring(), ring(MeetProto.string(1, "duplicate")), Data([0x0A, 0xFF])] {
            #expect(throws: MeetCallWire.WireError.malformedResponse) { try MeetPushWire.payload(data) }
        }
    }

    @Test func refusesUnsafeIDsAndOversizedPayloads() {
        let bad = MeetProto.bytes(2, MeetProto.string(1, "line\nbreak"))
        for data in [bad, Data(repeating: 0, count: 64001)] {
            #expect(throws: MeetCallWire.WireError.malformedResponse) { try MeetPushWire.payload(data) }
        }
    }

    @Test func unknownNotificationKindsAreIgnored() throws {
        #expect(try MeetPushWire.payload(MeetProto.bytes(4, Data())).map { _ in false } == nil)
        #expect(try MeetPushWire.events(in: ["noop"]).isEmpty)
    }

    @Test func preservesSubscriptionStatusWithoutRawMessage() throws {
        let response: PBLiteValue = [[["1", nil, [[14, "private-error"]]]]]
        let value: PBLiteValue = [response]
        guard case let .stopped(code) = try MeetPushWire.events(in: value).first else {
            Issue.record("Missing status"); return
        }
        #expect(code == 14)
    }

    @Test func shellConfigurationNeedsAllFieldsAndProduction() throws {
        let fields: [String: Any] = [
            "wU9aJb": "key-secret",
            "pZ68sc": "project-secret",
            "ttqQxf": "topic-secret"
        ]
        let config = try #require(MeetPushConfiguration.read(fields))
        #expect(!config.description.contains("secret"))
        #expect(MeetPushConfiguration.read(fields.merging(["TyXQle": 2]) { _, new in new }) == nil)
        #expect(MeetPushConfiguration.read(fields.filter { $0.key != "ttqQxf" }) == nil)
        #expect(MeetPushConfiguration(key: "line\nbreak", project: "project", topic: "topic") == nil)
        let json = try JSONSerialization
            .data(withJSONObject: fields.merging(["qwAQke": "DynamiteWebUi"]) { _, new in new })
        let html = "<script>window.WIZ_global_data=\(String(decoding: json, as: UTF8.self));</script>"
        #expect(WizGlobalData(html: html)?.meetPushConfiguration == config)
    }

    @Test func meetPrefixAndEndpointMatchTheSignalerSource() throws {
        let config = try #require(MeetPushConfiguration(key: "KEY", project: "PROJECT", topic: "TOPIC"))
        let requests = PunctualRequests(meet: config, endpoints: ChatEndpoints(account: .index(2)))
        let request = try requests.chooseServer(.meetRings(config))
        #expect(request.url.host == "signaler-pa.clients6.google.com")
        #expect(request.url.path == "/punctual/v1/chooseServer")
        #expect(request.headers["Origin"] == "https://chat.google.com")
        #expect(request.headers["X-Goog-AuthUser"] == "2")
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self)
            == #"[[null,null,null,[9,5],null,[["PROJECT"],[null,1],[[["TOPIC"]]]]],null,null,0,0]"#)
    }
}

extension MeetPushWireTests {
    @Test func sourceChannelAdapterUnwrapsSingleResponseBeforeReadingWatchAcknowledgement() throws {
        let watch: PBLiteValue = ["1", [["42"]]]
        let message: PBLiteValue = [[watch], nil, ["channel-secret"]]
        let events = try MeetPushWire.events(in: [message])
        #expect(events.count == 1)
        guard case .started = events.first
        else { Issue.record("Missing subscription acknowledgement"); return }
    }
}

extension MeetPushWireTests {
    @Test func envelopeDiagnosticsContainCountsWithoutOpaqueValues() {
        let watch: PBLiteValue = ["1", [["version-secret"]]]
        let response: PBLiteValue = [[watch], nil, ["channel-secret"]]
        #expect(MeetPushWire.envelopeSummary([response]) == "watch responses 1; matching sequence 1")
        #expect(MeetPushWire.envelopeSummary(["noop"]) == "control or unrecognized envelope")
        #expect(MeetPushWire
            .envelopeSummary([[["other-secret"]]]) == "watch responses 1; matching sequence 0")
    }
}
