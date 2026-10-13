import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

extension MeetDMCallTrialTests {
    private struct IncomingSetup {
        let trial: MeetDMCallTrial
        let transport: ScriptedTransport
        let incoming: MeetIncomingDMCalls
    }

    private func incomingSetup(
        native: Bool = false,
        decline: Bool = false,
        recordsReceipt: Bool = true
    ) async throws -> IncomingSetup {
        var responses = try loadingResponses()
        var shell = try responses[0].get()
        let html = String(decoding: shell.body, as: UTF8.self).replacingOccurrences(
            of: "\"qwAQke\"",
            with: "\"wU9aJb\":\"KEY\",\"pZ68sc\":\"PROJECT\",\"ttqQxf\":\"TOPIC\",\"qwAQke\""
        )
        shell.body = Data(html.utf8)
        responses[0] = .success(shell)
        if decline {
            responses.append(preparingResponses()[0])
            if recordsReceipt {
                responses.append(.success(HTTPResponse(status: 200, headers: HTTPHeaders([
                    ("x-goog-meeting-token", "80;receipt-token")
                ]), body: Data())))
            }
            responses.append(.success(HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())))
        } else if native {
            responses.append(preparingResponses()[0])
            responses.append(contentsOf: NativeMeetFixture.responses())
        } else {
            responses.append(contentsOf: preparingResponses())
        }
        let transport = ScriptedTransport(responses)
        let (trial, _) = try await trial(transport)
        _ = try await trial.loadPeople()
        return try await IncomingSetup(trial: trial, transport: transport, incoming: trial.incomingCalls())
    }

    private func incomingRing(
        code: String = "abc-defg-hij", meetingToken: String? = "70;notification-token",
        notificationSource: UInt8? = nil
    ) throws -> MeetPushWire.Ring {
        func string(_ field: UInt8, _ value: String) -> Data {
            Data([field << 3 | 2, UInt8(value.utf8.count)]) + Data(value.utf8)
        }
        var ring = string(1, "ring-secret") + string(2, code) + Data([0x20, 1])
            + string(8, "receiver-secret") + string(11, "dm/valid-dm") + Data([0x60, 2])
        if let meetingToken {
            ring += string(7, meetingToken)
        }
        if let notificationSource {
            ring += Data([0x90, 0x01, notificationSource])
        }
        let payload = Data([0x0A, UInt8(ring.count)]) + ring
        guard case let .ring(value) = try MeetPushWire.payload(payload) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return value
    }

    @Test func incomingAcceptResolvesTheOfferedDMAndCannotInvite() async throws {
        let setup = try await incomingSetup()
        let trial = setup.trial
        let transport = setup.transport
        let incoming = setup.incoming
        try await incoming.handle(.notification(.ring(incomingRing())))
        let offered = try #require(await incoming.offeredCall)
        let call = try await incoming.accept(offered.id)
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: call.id)
        }
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.prepareRingAfterBrowserJoin(preparedID: call.id)
        }
        #expect(await transport.sent.count == 6)
        #expect(await transport.sent.last?.url.path.hasSuffix("ResolveMeetingSpace") == true)
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("ResolveForHangoutsChat") })
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
        #expect(await trial.report.contains("invitations disabled"))
        await incoming.stop()
        await trial.close()
    }

    @Test func incomingResolverCanonicalAliasCanPrepareWithoutMediaOrInvite() async throws {
        let setup = try await incomingSetup()
        let trial = setup.trial
        let transport = setup.transport
        let incoming = setup.incoming
        try await incoming.handle(.notification(.ring(incomingRing(code: "xyz-abcd-efg"))))
        let offered = try #require(await incoming.offeredCall)
        let call = try await incoming.accept(offered.id)
        #expect(await transport.sent.count == 6)
        #expect(await trial.report.contains("server-resolved reference"))
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: call.id)
        }
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMediaSession") })
        await incoming.stop()
        await trial.close()
    }

    @Test func closedAccountScopeCannotAcceptAnEarlierRing() async throws {
        let setup = try await incomingSetup()
        let trial = setup.trial
        let transport = setup.transport
        let incoming = setup.incoming
        try await incoming.handle(.notification(.ring(incomingRing())))
        let offered = try #require(await incoming.offeredCall)
        await trial.close()
        await #expect(throws: MeetDMCallTrialError.superseded) { try await incoming.accept(offered.id) }
        #expect(await transport.sent.count == 4)
        await incoming.stop()
    }
}

extension MeetDMCallTrialTests {
    @Test func incomingBareSpaceIDMatchesTheSameDMAndStillCannotInvite() async throws {
        let setup = try await incomingSetup()
        try await setup.incoming.handle(.notification(.ring(incomingRing(code: "abc"))))
        let offered = try #require(await setup.incoming.offeredCall)
        let call = try await setup.incoming.accept(offered.id)
        #expect(await setup.trial.report
            .contains("Incoming call reference: 3 bytes; bare identifier; bare space ID"))
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await setup.trial.ring(preparedID: call.id)
        }
        #expect(await setup.transport.sent.count == 6)
        await setup.incoming.stop()
        await setup.trial.close()
    }
}

extension MeetDMCallTrialTests {
    @Test func tenCharacterIncomingCodeResolvesOfferedCallAndDisablesOutgoingInvites() async throws {
        let setup = try await incomingSetup()
        try await setup.incoming.handle(.notification(.ring(incomingRing(code: "abcdefghij"))))
        let offered = try #require(await setup.incoming.offeredCall)
        let call = try await setup.incoming.accept(offered.id)
        #expect(await setup.transport.sent.last?.url.path.hasSuffix("ResolveMeetingSpace") == true)
        #expect(await setup.transport.sent.last?.body == Data([0x0A, 0x0A]) + Data("abcdefghij".utf8))
        #expect(await setup.trial.report.contains("unhyphenated meeting code"))
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await setup.trial.ring(preparedID: call.id)
        }
        #expect(await setup.transport.sent.count == 6)
        await setup.incoming.stop()
        await setup.trial.close()
    }
}

extension MeetDMCallTrialTests {
    @MainActor
    @Test func resolvedAliasReachesNativeJoinedDeviceAndLeaveWithoutInvitingTheCaller() async throws {
        let setup = try await incomingSetup(native: true)
        try await setup.incoming.handle(.notification(.ring(incomingRing(code: "aliasvalue"))))
        let offered = try #require(await setup.incoming.offeredCall)
        let call = try await setup.incoming.accept(offered.id)
        let media = NativeFakeMedia()
        try await setup.trial.joinNative(preparedID: call.id, media: media)
        #expect(media.isConnected)
        #expect(await setup.trial.report.contains("server-resolved reference"))
        #expect(await setup.trial.report.contains("UpdateMeetingDevice: JOINED accepted"))
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await setup.trial.ring(preparedID: call.id)
        }
        await setup.trial.endNativeCall()
        #expect(!media.isConnected)
        let sent = await setup.transport.sent
        #expect(sent.count == 10)
        #expect(sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
        #expect(sent.allSatisfy { !$0.url.path.hasSuffix("ResolveForHangoutsChat") })
        let registration = try #require(sent.first { $0.url.path.hasSuffix("CreateMeetingDevice") }?.body)
        #expect(ProtoFieldScan.payloads(ofField: 4, in: registration) == [Data("ring-secret".utf8)])
        #expect(ProtoFieldScan.payloads(ofField: 5, in: registration) == [Data("receiver-secret".utf8)])
        #expect(await setup.trial.report.contains("device leave settled"))
        await setup.incoming.stop()
        await setup.trial.close()
    }
}

extension MeetDMCallTrialTests {
    @Test func explicitDeclineSendsReceiverContextWithoutResolvingOrStartingMedia() async throws {
        let setup = try await incomingSetup(decline: true)
        try await setup.incoming.handle(.notification(.ring(incomingRing())))
        let offered = try #require(await setup.incoming.offeredCall)
        try await setup.incoming.decline(offered.id)
        let sent = await setup.transport.sent
        try #require(sent.count == 7)
        #expect(sent[5].url.path.hasSuffix("LogEvent"))
        #expect(sent[5].headers["x-goog-meeting-token"] == "70;notification-token")
        #expect(sent[6].headers["x-goog-meeting-token"] == "80;receipt-token")
        #expect(sent[6].url.path.hasSuffix("DeclineMeetingInvite"))
        let body = try #require(sent[6].body)
        let context = try #require(ProtoFieldScan.payloads(ofField: 2, in: body).first)
        #expect(String(data: context, encoding: .utf8) == "receiver-secret")
        #expect(!sent.contains { $0.url.path.hasSuffix("ResolveMeetingSpace") })
        #expect(!sent.contains { $0.url.path.hasSuffix("CreateMediaSession") })
        #expect(!sent.contains { $0.url.path.hasSuffix("CreateMeetingInvite") })
        #expect(await setup.incoming.report.contains("DeclineMeetingInvite: accepted"))
        #expect(await !(setup.trial.report).contains("70;notification-token"))
        #expect(await !(setup.incoming.report).contains("70;notification-token"))
        #expect(await setup.incoming.offeredCall == nil)
        await setup.incoming.stop()
        await setup.trial.close()
    }
}

extension MeetDMCallTrialTests {
    @Test func missingNotificationTokenRefusesDeclineBeforeAnyMeetRequest() async throws {
        let setup = try await incomingSetup(decline: true)
        try await setup.incoming.handle(.notification(.ring(incomingRing(meetingToken: nil))))
        let offered = try #require(await setup.incoming.offeredCall)
        await #expect(throws: MeetCallClientError.missingMeetingToken) {
            try await setup.incoming.decline(offered.id)
        }
        #expect(await setup.transport.sent.count == 4)
        #expect(await setup.trial.report.contains("notification meeting token absent; request not sent"))
        #expect(await setup.incoming.offeredCall == nil)
        await setup.incoming.stop()
        await setup.trial.close()
    }
}

extension MeetDMCallTrialTests {
    @Test func sourceTwoDeclineSkipsReceiptAndStillUsesItsOwnNotificationToken() async throws {
        let setup = try await incomingSetup(decline: true, recordsReceipt: false)
        try await setup.incoming.handle(.notification(.ring(incomingRing(notificationSource: 2))))
        let offered = try #require(await setup.incoming.offeredCall)
        try await setup.incoming.decline(offered.id)
        let sent = await setup.transport.sent
        try #require(sent.count == 6)
        #expect(!sent.contains { $0.url.path.hasSuffix("LogEvent") })
        #expect(sent[5].url.path.hasSuffix("DeclineMeetingInvite"))
        #expect(sent[5].headers["x-goog-meeting-token"] == "70;notification-token")
        #expect(await setup.trial.report.contains("receipt skipped for notification source2"))
        await setup.incoming.stop()
        await setup.trial.close()
    }
}
