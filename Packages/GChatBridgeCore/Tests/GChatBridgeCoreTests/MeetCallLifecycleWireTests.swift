import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCallLifecycleWireTests {
    @Test func fullCollectionsUseDistinctRequestAndResponseFieldsAndVersions() throws {
        let request = try MeetCallCollectionsWire.sync(space: "spaces/demo")
        #expect(try MeetProto.text(1, request) == "spaces/demo")
        #expect(try MeetProto.payload(3, request).isEmpty)
        #expect(try MeetProto.payload(12, request).isEmpty)
        let device = MeetProto.string(1, "spaces/demo/devices/peer") + MeetProto.number(4, 1)
        let invite = MeetProto.string(1, "opaque-invite")
        let fullDevices = full(version: 12, entries: [device])
        let fullInvites = full(version: 17, entries: [invite])
        let reply = encoded(MeetProto.bytes(2, MeetProto.bytes(2, fullDevices))
            + MeetProto.bytes(11, MeetProto.bytes(2, fullInvites)))
        let result = try MeetCallCollectionsWire.snapshot(from: reply, in: "spaces/demo")
        #expect(result.devices?.version == 12)
        #expect(result.devices?.values.first?.joinState == 1)
        #expect(result.invitations?.version == 17)
        #expect(result.invitations?.ids == ["opaque-invite"])
    }

    @Test func absentAndUnmodifiedCollectionsAreNotEmptyFullSnapshots() throws {
        let reply = encoded(MeetProto.bytes(2, MeetProto.bytes(1, Data())))
        let result = try MeetCallCollectionsWire.snapshot(from: reply, in: "spaces/demo")
        #expect(result.devices == nil)
        #expect(result.invitations == nil)
        let empty = try MeetCallCollectionsWire.snapshot(
            from: encoded(MeetProto.bytes(2, MeetProto.bytes(2, full(version: 1, entries: [])))),
            in: "spaces/demo"
        )
        #expect(empty.devices?.values.isEmpty == true)
    }

    @Test func invitationStatusComesFromRawFieldSixAndUnknownValuesRemainNonterminal() throws {
        for (extra, expected) in [
            (Data(), UInt64(0)), (MeetProto.number(6, 7), 7),
            (MeetProto.number(6, 99), 99), (MeetProto.number(7, 7), 0)
        ] {
            let entry = MeetProto.string(1, "opaque-invite") + extra
            let body = encoded(MeetProto.bytes(11, MeetProto.bytes(2, full(version: 1, entries: [entry]))))
            let result = try MeetCallCollectionsWire.snapshot(from: body, in: "spaces/demo")
            #expect(result.invitations?.values.first?.status == expected)
        }
        for extra in [
            MeetProto.number(6, 7) + MeetProto.number(6, 2),
            MeetProto.string(6, "invalid"),
            MeetProto.number(6, UInt64.max)
        ] {
            let entry = MeetProto.string(1, "opaque-invite") + extra
            let body = encoded(MeetProto.bytes(11, MeetProto.bytes(2, full(version: 1, entries: [entry]))))
            #expect(throws: MeetCallWire.WireError.self) {
                try MeetCallCollectionsWire.snapshot(from: body, in: "spaces/demo")
            }
        }
    }

    @Test func malformedAmbiguousWrongSpaceAndDuplicateDevicesCannotEndACall() throws {
        let good = MeetProto.string(1, "spaces/demo/devices/peer") + MeetProto.number(4, 1)
        let wrong = MeetProto.string(1, "spaces/other/devices/peer") + MeetProto.number(4, 6)
        for payload in [
            MeetProto.bytes(
                2,
                MeetProto.bytes(1, Data()) + MeetProto.bytes(2, full(version: 2, entries: []))
            ),
            MeetProto.bytes(2, MeetProto.bytes(2, full(version: 2, entries: [wrong]))),
            MeetProto.bytes(2, MeetProto.bytes(2, full(version: 2, entries: [good, good]))),
            MeetProto.bytes(2, MeetProto.bytes(2, Data())), Data([0x12, 0xFF])
        ] {
            #expect(throws: MeetCallWire.WireError.self) {
                try MeetCallCollectionsWire.snapshot(from: encoded(payload), in: "spaces/demo")
            }
        }
    }

    @Test func declineBodyUsesInvitationAndReceiverContext() throws {
        let invitation = try MeetIncomingInvitation(id: "invitation", clientID: "receiver")
        let decline = try MeetInvitationWire.decline(invitation)
        #expect(try MeetProto.text(1, decline) == "invitation")
        #expect(try MeetProto.text(2, decline) == "receiver")
        #expect(ProtoFieldScan.fields(in: decline).fields.map(\.number) == [1, 2])
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetInvitationWire.decline(MeetIncomingInvitation(id: "invitation", clientID: nil))
        }
        #expect(try MeetProto.text(1, MeetInvitationWire.cancel(id: "opaque-invite")) == "opaque-invite")
    }

    @Test func explicitDeclineRecordsReceiptAndUsesRotatedTokenWithoutResolveOrMedia() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("x-goog-meeting-token", "80;receipt")]),
                body: Data()
            ),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        ])
        let client = try client(transport)
        let receipt = try await client.decline(
            MeetIncomingInvitation(id: "invitation", clientID: "receiver"),
            meetingToken: "70;notification-token"
        )
        let sent = await transport.sent
        try #require(sent.count == 2)
        guard case .acknowledged = receipt else { Issue.record("Receipt not acknowledged"); return }
        #expect(sent[0].url.path.hasSuffix("LogEvent"))
        #expect(sent[1].url.path.hasSuffix("DeclineMeetingInvite"))
        #expect(sent[0].headers["Authorization"] != nil)
        #expect(sent[0].headers["x-goog-meeting-token"] == "70;notification-token")
        #expect(sent[1].headers["x-goog-meeting-token"] == "80;receipt")
        #expect(sent[0].timeout == .seconds(3))
        let receiptBody = try #require(sent[0].body)
        #expect(try MeetProto.text(1, receiptBody) == "invitation")
        #expect(try MeetProto.text(2, receiptBody) == "receiver")
        #expect(try MeetProto.value(3, receiptBody) == 1)
        #expect(try MeetProto.value(4, receiptBody) == 2)
        #expect(try MeetProto.text(2, #require(sent[1].body)) == "receiver")
    }

    @Test func unsafeOrMalformedNotificationTokenCannotSendADecline() async throws {
        let transport = FakeHTTPTransport(responses: [])
        let client = try client(transport)
        let invitation = try MeetIncomingInvitation(id: "invitation", clientID: "receiver")
        for token in ["", "receiver", "70;", "bad;token", "70;line\nbreak", "70;null\0byte", "70; space"] {
            await #expect(throws: MeetCallClientError.missingMeetingToken) {
                try await client.decline(invitation, meetingToken: token)
            }
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test func sourceTwoSkipsReceiptAndFailedReceiptDoesNotSkipDeclineOrLoseErrorToken() async throws {
        let invitation = try MeetIncomingInvitation(id: "invitation", clientID: "receiver")
        let skippedTransport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        ])
        let skipped = try await client(skippedTransport).decline(
            invitation,
            meetingToken: "70;notification",
            recordsReceipt: false
        )
        guard case .skipped = skipped else { Issue.record("Unexpected receipt request"); return }
        #expect(await skippedTransport.sent.count == 1)
        #expect(await skippedTransport.sent[0].url.path.hasSuffix("DeclineMeetingInvite"))
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 500,
                headers: HTTPHeaders([("x-goog-meeting-token", "80;error")]),
                body: encoded(MeetProto.number(1, 13))
            ),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        ])
        let receipt = try await client(transport).decline(invitation, meetingToken: "70;notification")
        guard case .unconfirmed = receipt else { Issue.record("False receipt acknowledgement"); return }
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(sent[1].headers["x-goog-meeting-token"] == "80;error")
        #expect(sent.map(\.url.lastPathComponent) == ["LogEvent", "DeclineMeetingInvite"])
    }

    private actor DeclineValidation {
        var attempts = 0
        func validate() throws {
            attempts += 1
            if attempts == 2 {
                throw MeetCallClientError.missingSessionProof
            }
        }
    }

    @Test func accountValidationBetweenReceiptAndDeclinePreventsTheSecondMutation() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        ])
        let validation = DeclineValidation()
        let client = try client(transport)
        await #expect(throws: MeetCallClientError.missingSessionProof) {
            try await client.decline(
                MeetIncomingInvitation(id: "invitation", clientID: "receiver"),
                meetingToken: "70;notification",
                validate: { try await validation.validate() }
            )
        }
        #expect(await transport.sent.count == 1)
        #expect(await transport.sent[0].url.path.hasSuffix("LogEvent"))
    }

    @Test func cancellationRotatesTokenForLeaveAndIsNeverAutomaticallyRepeated() async throws {
        let transport = FakeHTTPTransport(responses: [
            device(2), device(1), HTTPResponse(
                status: 200,
                headers: HTTPHeaders([]),
                body: encoded(MeetProto.string(1, "invite"))
            ),
            HTTPResponse(
                status: 500,
                headers: HTTPHeaders([("x-goog-meeting-token", "40;error")]),
                body: encoded(MeetProto.number(1, 13))
            ), device(6)
        ])
        let call = try MeetResolvedCall(space: .init(
            name: "spaces/demo",
            code: "abc-defg-hij",
            url: #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        ), token: "10;resolve")
        let session = try MeetDeviceSession(client: client(transport), call: call)
        try await session.register(mediaSession: "mediasessions/native")
        await session.setMediaConnected(true)
        try await session.join()
        try await session.invite(calleeID: "peer", requestID: UUID())
        await #expect(throws: MeetCallClientError.self) { try await session.cancelInvitation() }
        await #expect(throws: MeetDeviceSessionError.invitationCancellationUnconfirmed) {
            try await session.cancelInvitation()
        }
        try await session.leave()
        let sent = await transport.sent
        #expect(sent.count == 5)
        #expect(sent[3].url.path.hasSuffix("CancelMeetingInvite"))
        #expect(try MeetProto.text(1, #require(sent[3].body)) == "invite")
        #expect(sent[4].headers["x-goog-meeting-token"] == "40;error")
    }

    private func full(version: UInt64, entries: [Data]) -> Data {
        entries.reduce(MeetProto.bytes(1, MeetProto.number(1, version))) { $0 + MeetProto.bytes(2, $1) }
    }

    private func encoded(_ data: Data) -> Data {
        Data(data.base64EncodedString().utf8)
    }

    private func device(_ state: UInt64) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: encoded(
            MeetProto.string(1, "spaces/demo/devices/one") + MeetProto.number(4, state)
        ))
    }

    private func client(_ transport: FakeHTTPTransport) throws -> MeetCallClient {
        let configuration = try #require(MeetCallConfiguration(
            apiKey: "key",
            accountIndex: 0,
            referer: URL(string: "https://meet.google.com/call")!,
            userAgent: "Test",
            rtcClientID: "CAEQABgB",
            debugID: "test"
        ))
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "SAPISID", value: "synthetic", domain: ".google.com", path: "/")
        ]))
        return MeetCallClient(
            transport: transport,
            credentials: SessionCredentials(cookies),
            configuration: configuration,
            sha1: { _ in "synthetic" }
        )
    }
}
