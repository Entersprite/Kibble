import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetActivityDataTests {
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

    @Test func incomingReactionsUseTheReportedDeviceAndNeverGuessARosterPosition() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        let entry = NativeMeetFixture.bytes(1, NativeMeetFixture.string(1, "👍"))
            + NativeMeetFixture.bytes(
                6,
                NativeMeetFixture.string(1, "unknown")
                    + NativeMeetFixture.string(2, "Reported Name")
            )
        let frame = NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(1, entry))
        await session.receiveActivityData(channel: "reactions", data: frame)
        #expect(await session.activities.reactions.first?.sender == "Reported Name")
        #expect(await session.activities.reactions.first?.participantID == nil)
        await session.close()
        await session.receiveActivityData(channel: "reactions", data: frame)
        #expect(await session.activities.reactions.count == 1)
    }

    private func reply(sequence: UInt64, code: UInt64, message: Data) -> Data {
        NativeMeetFixture.bytes(
            1,
            NativeMeetFixture.number(1, sequence)
                + NativeMeetFixture.bytes(2, NativeMeetFixture.number(1, code))
                + NativeMeetFixture.bytes(4, NativeMeetFixture.bytes(1, message))
        )
    }
}

extension NativeFakeMedia {
    func exchangeActivityData(
        channel: String, data: Data, matches: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        sentActivityFrames.append((channel, data))
        guard isConnected, let activityReply, matches(activityReply) else {
            throw CallMediaError.connectionFailed
        }
        return activityReply
    }
}
