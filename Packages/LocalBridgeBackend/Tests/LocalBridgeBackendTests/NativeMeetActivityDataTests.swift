import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetActivityDataTests {
    @Test func waitingRoomChatUsesTheJoinedGrantAndKeepsBothAudiencesSeparate() async throws {
        let everyone = meetingMessage("public", text: "Hello everyone", recipient: 0)
        let restricted = meetingMessage("waiting", text: "Please wait", recipient: 2)
        let start = waitingChatSnapshot(1, grant: true, messages: [everyone, restricted])
        let (session, media) = try await waitingChatCall([start, start])
        await session.refreshState()
        let first = await session.activities
        #expect(first.availableActions.contains("chatWaitingRoom"))
        #expect(first.messages.map(\.text) == ["Hello everyone"])
        #expect(first.waitingRoomMessages?.map(\.text) == ["Please wait"])

        let text = "Hello\nWe will admit you shortly"
        media.activityReply = reply(
            sequence: 1,
            code: 0,
            message: meetingMessage("next", text: text, recipient: 2)
        )
        try await session.performActivity(CallActivity("chatWaitingRoom", text: text))
        let message = NativeMeetFixture.number(3, 1)
            + NativeMeetFixture.bytes(5, NativeMeetFixture.string(1, text))
            + NativeMeetFixture.number(6, 1) + NativeMeetFixture.number(10, 2)
        let frame = NativeMeetFixture.bytes(
            1, NativeMeetFixture.number(1, 1)
                + NativeMeetFixture.bytes(3, NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(2, message)))
        )
        #expect(media.sentActivityFrames.count == 1)
        #expect(media.sentActivityFrames.first?.0 == "meet_messages")
        #expect(media.sentActivityFrames.first?.1 == frame)
        let after = await session.activities
        #expect(after.messages == first.messages)
        #expect(after.waitingRoomMessages?.map(\.text) == ["Please wait", text])
        let waitingRow = try #require(after.waitingRoomMessages?.last)
        #expect(waitingRow.isPinned == nil && waitingRow.canChangePin == nil)
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("setMeetingMessagePin", resourceID: waitingRow.id))
        }
        #expect(media.sentActivityFrames.count == 1)
        await session.close()
        #expect(await session.activities.waitingRoomMessages == nil)
    }

    @Test(arguments: ["missing-grant", "revoked", "old-roster", "unassigned", "closed"])
    func waitingRoomSendRequiresACurrentGrantAndOpenAssignment(_ scenario: String) async throws {
        let start = waitingChatSnapshot(4, grant: scenario != "missing-grant")
        let fresh = waitingChatSnapshot(scenario == "old-roster" ? 3 : 4, grant: scenario != "revoked")
        let (session, media) = try await waitingChatCall([start, fresh], assigned: scenario != "unassigned")
        await session.refreshState()
        if scenario == "closed" {
            await session.handleActivityChannelClosed("meet_messages")
        }
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("chatWaitingRoom", text: "Please wait"))
        }
        #expect(media.sentActivityFrames.isEmpty)
        if scenario != "old-roster" {
            #expect(await !session.activities.availableActions.contains("chatWaitingRoom"))
        }
        await session.close()
    }

    @Test(arguments: ["public", "wrong-text", "refused"])
    func waitingRoomSendDoesNotConfirmAMismatchedReceipt(_ scenario: String) async throws {
        let start = waitingChatSnapshot(1, grant: true, messages: [])
        let (session, media) = try await waitingChatCall([start, start])
        await session.refreshState()
        let message = meetingMessage(
            "receipt", text: scenario == "wrong-text" ? "Changed" : "Please wait",
            recipient: scenario == "public" ? 0 : 2
        )
        media.activityReply = reply(sequence: 1, code: scenario == "refused" ? 7 : 0, message: message)
        await #expect(throws: (any Error).self) {
            try await session.performActivity(CallActivity("chatWaitingRoom", text: "Please wait"))
        }
        #expect(await session.activities.messages.isEmpty)
        #expect(await session.activities.waitingRoomMessages?.isEmpty == true)
        #expect(media.sentActivityFrames.count == 1)
        await session.close()
    }

    @Test(arguments: [UInt64(1), 2])
    func waitingRoomSendReadbackRequiresTheExactSequence(sequence: UInt64) async throws {
        let text = "Please wait"
        let before = waitingChatSnapshot(1, grant: true)
        let message = meetingMessage("confirmed", text: text, recipient: 2)
            + NativeMeetFixture.string(2, "spaces/demo/devices/one")
            + NativeMeetFixture.number(3, sequence)
        let after = waitingChatSnapshot(2, grant: true, messages: [message])
        let (session, media) = try await waitingChatCall([before, before, after])
        await session.refreshState()
        media.activityExchange = { throw CallMediaError.signalingTimedOut }
        let activity = CallActivity("chatWaitingRoom", text: text)
        if sequence == 1 {
            try await session.performActivity(activity)
            #expect(await session.activities.waitingRoomMessages?.map(\.text) == [text])
        } else {
            await #expect(throws: ChatError.self) { try await session.performActivity(activity) }
            #expect(await session.activities.waitingRoomMessages?.isEmpty == true)
        }
        #expect(media.sentActivityFrames.count == 1)
        await session.close()
    }

    @Test func anAddressedCreateResultCanOmitTheDefaultStatus() throws {
        let message = meetingMessage("confirmed", text: "Please wait", recipient: 2)
        let body = NativeMeetFixture.number(1, 31)
        let frame = NativeMeetFixture.bytes(
            1,
            body + NativeMeetFixture.bytes(4, NativeMeetFixture.bytes(1, message))
        )
        #expect(!MeetActivityDataWire.isChatResponse(NativeMeetFixture.bytes(1, body), sequence: 31))
        #expect(!MeetActivityDataWire.isChatResponse(frame, sequence: 32))
        #expect(try MeetActivityDataWire
            .chatResponse(frame, sequence: 31, recipient: .waitingRoom) == message)
    }

    @Test func thePrimarySessionInstallsOnlyConfirmedActivitiesBeforeTheAnswer() async throws {
        let assignment = NativeMeetFixture.bytes(
            12,
            NativeMeetFixture.string(1, "meet_messages")
                + NativeMeetFixture.number(2, 1) + NativeMeetFixture.number(3, 42)
                + NativeMeetFixture.number(6, 0)
        )
        let transport = ScriptedTransport(NativeMeetFixture.responses(activityChannels: assignment))
        let media = NativeFakeMedia()
        media.supportsActivityChannelAssignments = true
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()

        let sent = await transport.sent
        let create = try #require(sent.first { $0.url.path.hasSuffix("CreateMediaSession") }?.body)
        let envelope = try #require(ProtoFieldScan.payloads(ofField: 1, in: create).first)
        let configuration = try #require(ProtoFieldScan.payloads(ofField: 3, in: envelope).first)
        let labels = ProtoFieldScan.payloads(ofField: 17, in: configuration).compactMap {
            ProtoFieldScan.payloads(ofField: 1, in: $0).first
        }
        #expect(labels == ["reactions", "meet_messages", "captions_v2"].map { Data($0.utf8) })
        #expect(media.calls.prefix(4) == ["offer", "meet_messages", "answer", "connected"])
        #expect(media.activityChannelAssignments == [
            "meet_messages": CallStreamControlChannel(id: 42, isOrdered: true, maxRetransmits: 0)
        ])
        let actions = await session.activities.availableActions
        #expect(actions.contains("chat") && !actions.contains("react"))
        #expect(media.isConnected)
        await session.close()
    }

    @Test func standaloneChatPublishesOnlyAcknowledgedMessagesAndDoesNotReplayARefusal() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        await session.updateActivityAvailability()
        let text = NativeMeetFixture.bytes(5, NativeMeetFixture.string(1, "hello"))
        let message = NativeMeetFixture.string(1, "message-one") + text + NativeMeetFixture.number(6, 1)
        media.activityReply = reply(sequence: 1, code: 0, message: message)
        try await session.performActivity(CallActivity("chat", text: "hello"))
        #expect(await session.activities.messages.map(\.text) == ["hello"])
        #expect(media.sentActivityFrames.count == 1 && media.sentActivityFrames.first?.0 == "meet_messages")
        media.activityReply = reply(sequence: 2, code: 7, message: Data())
        await #expect(throws: MeetActivityDataWire.MessageError.self) {
            try await session.performActivity(CallActivity("chat", text: "refused"))
        }
        #expect(await session.activities.messages.map(\.text) == ["hello"])
        #expect(media.sentActivityFrames.count == 2 && media.isConnected)
        #expect(await transport.sent.count == 4)
        await session.close()
    }

    @Test func otherAudiencesCannotEnterTheOrdinaryTranscriptFromCollectionsOrReceipts() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        await session.updateActivityAvailability()
        let omitted = chatMessage("omitted")
        let everyone = chatMessage("everyone") + NativeMeetFixture.number(10, 0)
        let inCall = chatMessage("in-call") + NativeMeetFixture.number(10, 4)
        let waiting = chatMessage("waiting") + NativeMeetFixture.number(10, 2)
        let unknown = chatMessage("unknown") + NativeMeetFixture.number(10, 99)
        let ambiguous = chatMessage("ambiguous") + NativeMeetFixture.number(10, 0) + NativeMeetFixture.number(
            10,
            2
        )
        let first = try messages([omitted, everyone, inCall, waiting, unknown, ambiguous], version: 1)
        await session.reconcileActivities(first)
        #expect(await session.activities.messages.map(\.text) == ["omitted", "everyone", "in-call"])

        let changed = chatMessage("everyone") + NativeMeetFixture.number(10, 2)
        let second = try messages([omitted, changed], version: 2)
        await session.reconcileActivities(second)
        #expect(await session.activities.messages.map(\.text) == ["omitted"])

        media.activityReply = reply(sequence: 1, code: 0, message: waiting)
        await #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try await session.performActivity(CallActivity("chat", text: "waiting"))
        }
        #expect(await session.activities.messages.map(\.text) == ["omitted"])
        #expect(media.sentActivityFrames.count == 1)
        media.activityReply = reply(sequence: 2, code: 0, message: inCall)
        try await session.performActivity(CallActivity("chat", text: "in-call"))
        #expect(await session.activities.messages.map(\.text) == ["omitted", "in-call"])
        #expect(media.sentActivityFrames.count == 2)
        await session.close()
    }

    @Test func anOlderCollectionCannotEraseAnAcknowledgedMessage() async throws {
        let initial = waitingChatSnapshot(4, grant: false)
        let outbound = meetingMessage("outbound", text: "Hello", recipient: 4)
        let inbound = meetingMessage("inbound", text: "Reply", recipient: 1)
        let fresh = waitingChatSnapshot(5, grant: false, messages: [outbound, inbound])
        let (session, media) = try await waitingChatCall([initial, initial, fresh])
        await session.refreshState()
        media.activityReply = reply(sequence: 1, code: 0, message: outbound, revision: 5)
        try await session.performActivity(CallActivity("chat", text: "Hello"))
        await session.refreshState()
        #expect(await session.activities.messages.map(\.text) == ["Hello"])
        await session.refreshState()
        #expect(await session.activities.messages.map(\.text) == ["Hello", "Reply"])
        await session.close()
    }

    private func chatMessage(_ name: String) -> Data {
        NativeMeetFixture.string(1, name) + NativeMeetFixture.bytes(5, NativeMeetFixture.string(1, name))
            + NativeMeetFixture.number(6, 1)
    }

    private func messages(_ rows: [Data], version: UInt64) throws -> MeetActivityCollections.Snapshot {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let full = rows.reduce(into: metadata) { $0 += NativeMeetFixture.bytes(2, $1) }
        let body = NativeMeetFixture.bytes(3, NativeMeetFixture.bytes(2, full)).base64EncodedData()
        return try MeetActivityCollections.decode(body, space: "spaces/demo")
    }

    @Test(arguments: [false, true])
    func chatDiscardsAnAcknowledgementAfterTheCallCloses(waitingRoom: Bool) async throws {
        let snapshot = waitingChatSnapshot(1, grant: waitingRoom)
        let (session, media) = try await waitingChatCall([snapshot, snapshot])
        await session.refreshState()
        let message = meetingMessage("late-message", text: "late", recipient: waitingRoom ? 2 : 0)
        let reply = reply(sequence: 1, code: 0, message: message)
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (closed, signalClose) = AsyncStream<Void>.makeStream()
        let (release, resumeExchange) = AsyncStream<Void>.makeStream()
        media.onClose = { signalClose.finish() }
        media.activityExchange = {
            signalStart.finish()
            for await _ in release {}
            return reply
        }

        let action = waitingRoom ? "chatWaitingRoom" : "chat"
        let send = Task { try await session.performActivity(CallActivity(action, text: "late")) }
        for await _ in started {}
        let close = Task { await session.close() }
        for await _ in closed {}
        resumeExchange.finish()

        await #expect(throws: CancellationError.self) { try await send.value }
        await close.value
        #expect(await session.activities.messages.isEmpty)
        #expect(await session.activities.waitingRoomMessages == nil)
        #expect(media.sentActivityFrames.count == 1)
    }

    @Test func incomingReactionsUseTheReportedDeviceAndNeverGuessARosterPosition() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        await session.startMonitoring(receive: { _ in })
        let handler = try #require(media.eventHandler)
        let entry = NativeMeetFixture.bytes(1, NativeMeetFixture.string(1, "👍"))
            + NativeMeetFixture.bytes(
                6,
                NativeMeetFixture.string(1, "unknown")
                    + NativeMeetFixture.string(2, "Reported Name")
            )
            + NativeMeetFixture.bytes(
                6,
                NativeMeetFixture.string(1, "another-unknown")
                    + NativeMeetFixture.string(2, "Another Participant")
            )
        let frame = NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(1, entry))
        await handler(.activityData(channel: "reactions", data: frame))
        let reactions = await session.activities.reactions
        #expect(reactions.map(\.sender) == ["Reported Name", "Another Participant"])
        #expect(reactions.allSatisfy { $0.emoji == "👍" && $0.participantID == nil })
        await session.close()
        await handler(.activityData(channel: "reactions", data: frame))
        #expect(await session.activities.reactions == reactions)
    }
}

private extension NativeMeetActivityDataTests {
    func reply(sequence: UInt64, code: UInt64, message: Data, revision: UInt64? = nil) -> Data {
        var update = NativeMeetFixture.bytes(1, message)
        if let revision {
            update += NativeMeetFixture.string(5, "\(revision)-version")
        }
        return NativeMeetFixture.bytes(
            1,
            NativeMeetFixture.number(1, sequence)
                + NativeMeetFixture.bytes(2, NativeMeetFixture.number(1, code))
                + NativeMeetFixture.bytes(4, update)
        )
    }

    func waitingChatCall(
        _ reads: [Result<HTTPResponse, any Error>], assigned: Bool = true
    ) async throws -> (NativeMeetCallSession, NativeFakeMedia) {
        let assignment = NativeMeetFixture.bytes(
            12, NativeMeetFixture.string(1, "meet_messages") + NativeMeetFixture.number(3, 42)
        )
        let setup = NativeMeetFixture.responses(activityChannels: assigned ? assignment : Data())
        let transport = ScriptedTransport(Array(setup.prefix(4)) + reads + Array(setup.suffix(1)))
        let media = NativeFakeMedia()
        media.supportsActivityChannelAssignments = true
        let session = try await NativeMeetFixture.session(transport, media: media, staysWhenAlone: true)
        try await session.connect()
        return (session, media)
    }

    func waitingChatSnapshot(
        _ version: UInt64, grant: Bool, messages: [Data] = []
    ) -> Result<HTTPResponse, any Error> {
        let local = NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, 1)
            + (grant ? NativeMeetFixture.number(13, 113) : Data())
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let roster = metadata + NativeMeetFixture.bytes(2, local)
        let history = messages.reduce(into: metadata) { $0 += NativeMeetFixture.bytes(2, $1) }
        return NativeMeetFixture.ok(
            NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, roster))
                + NativeMeetFixture.bytes(3, NativeMeetFixture.bytes(2, history))
        )
    }

    func meetingMessage(_ name: String, text: String, recipient: UInt64) -> Data {
        NativeMeetFixture.string(1, name) + NativeMeetFixture.bytes(5, NativeMeetFixture.string(1, text))
            + NativeMeetFixture.number(6, 1) + NativeMeetFixture.number(10, recipient)
    }
}

extension NativeFakeMedia {
    func sendActivityData(channel: String, data: Data) async throws {
        guard isConnected else { throw CallMediaError.connectionFailed }
        sentActivityFrames.append((channel, data))
    }

    func exchangeActivityData(
        channel: String, data: Data, matches: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        sentActivityFrames.append((channel, data))
        if let activityExchange {
            return try await activityExchange()
        }
        let response = activityReplies.isEmpty ? activityReply : activityReplies.removeFirst()
        guard isConnected, let response, matches(response) else {
            throw CallMediaError.connectionFailed
        }
        return response
    }
}
