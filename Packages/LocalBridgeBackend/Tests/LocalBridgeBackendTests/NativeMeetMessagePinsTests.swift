import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetMessagePinsTests {
    private let local = "spaces/demo/devices/one"
    private let other = "spaces/demo/devices/another"
    private let messageName = "message-one"

    private struct ConnectedCall {
        let session: NativeMeetCallSession
        let media: NativeFakeMedia
        let transport: ScriptedTransport
    }

    @Test(arguments: [true, false])
    func aMatchingNextRevisionUpdatesOnlyTheAddressedMessage(pin: Bool) async throws {
        let target = message(sender: pin ? local : other, pinned: !pin)
        let second = message(name: "another-message", sender: other, pinned: false)
        let before = snapshot(5, messages: [target, second])
        let call = try await connect([before, before, before])
        let session = call.session, media = call.media, transport = call.transport
        await session.refreshState()
        let original = await session.activities.messages
        let row = try #require(original.first)
        #expect(row.isPinned == !pin && row.canChangePin == true)
        media.activityReply = reply(revision: 6, pinned: pin)
        try await session.performActivity(CallActivity(
            "setMeetingMessagePin",
            resourceID: row.id,
            enabled: pin
        ))
        let patch = NativeMeetFixture.string(1, messageName) + NativeMeetFixture.number(7, pin ? 1 : 0)
        let update = NativeMeetFixture.bytes(1, patch) + NativeMeetFixture.bytes(
            2, NativeMeetFixture.string(1, "is_pinned")
        )
        let body = NativeMeetFixture.number(1, 1) + NativeMeetFixture.bytes(
            4,
            NativeMeetFixture.bytes(1, update)
        )
        #expect(media.sentActivityFrames.count == 1)
        #expect(media.sentActivityFrames.first?.0 == "meet_messages")
        #expect(media.sentActivityFrames.first?.1 == NativeMeetFixture.bytes(1, body))
        #expect(await transport.sent.count == 6)
        await session.refreshState()
        let current = await session.activities.messages
        #expect(current.map(\.id) == original.map(\.id))
        #expect(current.first?.isPinned == pin && current.first?.canChangePin == (pin ? true : nil))
        #expect(current.last == original.last)
        await session.close()
    }

    @Test(arguments: ["other", "lost-host", "gone", "private", "not-joined", "older", "closed-channel"])
    func preflightRequiresACurrentJoinedDeviceAndAnEligibleExactRow(_ scenario: String) async throws {
        let pin = scenario != "lost-host"
        let target = message(sender: pin ? local : other, pinned: !pin)
        let start = snapshot(5, messages: [target])
        let fresh = snapshot(
            scenario == "older" ? 4 : 6,
            messages: scenario == "gone" ? [] : [
                message(
                    sender: scenario == "other" || !pin ? other : local,
                    pinned: !pin,
                    recipient: scenario == "private" ? 2 : 0
                )
            ],
            role: scenario == "lost-host" ? 3 : 1,
            state: scenario == "not-joined" ? 7 : 1
        )
        let call = try await connect([start, fresh])
        let session = call.session, media = call.media
        await session.refreshState()
        let row = try #require(await session.activities.messages.first)
        if scenario == "closed-channel" {
            await session.handleActivityChannelClosed("meet_messages")
            let actions = await session.activities.availableActions
            #expect(!actions.contains("chat") && !actions.contains("setMeetingMessagePin"))
        }
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity(
                "setMeetingMessagePin",
                resourceID: row.id,
                enabled: pin
            ))
        }
        #expect(media.sentActivityFrames.isEmpty)
        await session.close()
    }

    @Test(arguments: ["sparse", "gap", "stale", "foreign", "refused"])
    func ambiguousReceiptsUseOneNewerReadWithoutRepeatingTheUpdate(_ scenario: String) async throws {
        let start = snapshot(5, messages: [message(sender: local, pinned: false)])
        let confirmed = snapshot(
            scenario == "stale" ? 5 : 7,
            messages: [message(sender: local, pinned: true)]
        )
        let canReadBack = !["foreign", "refused"].contains(scenario)
        let call = try await connect([start, start] + (canReadBack ? [confirmed] : []))
        let session = call.session, media = call.media, transport = call.transport
        await session.refreshState()
        let row = try #require(await session.activities.messages.first)
        media.activityReply = reply(
            revision: scenario == "gap" ? 7 : 6, pinned: true,
            name: scenario == "foreign" ? "different-message" : nil,
            code: scenario == "refused" ? 7 : 0, sparse: ["sparse", "stale"].contains(scenario)
        )
        let action = CallActivity("setMeetingMessagePin", resourceID: row.id)
        let succeeds = scenario == "sparse" || scenario == "gap"
        if succeeds {
            try await session.performActivity(action)
        } else {
            await #expect(throws: (any Error).self) { try await session.performActivity(action) }
        }
        #expect(media.sentActivityFrames.count == 1)
        #expect(await transport.sent.count == (canReadBack ? 7 : 6))
        #expect(await session.activities.messages.first?.isPinned == succeeds)
        await session.close()
    }

    private func connect(
        _ reads: [Result<HTTPResponse, any Error>]
    ) async throws -> ConnectedCall {
        let assignment = NativeMeetFixture.bytes(
            12, NativeMeetFixture.string(1, "meet_messages") + NativeMeetFixture.number(3, 42)
        )
        let setup = NativeMeetFixture.responses(activityChannels: assignment)
        let transport = ScriptedTransport(Array(setup.prefix(4)) + reads + Array(setup.suffix(1)))
        let media = NativeFakeMedia()
        media.supportsActivityChannelAssignments = true
        let session = try await NativeMeetFixture.session(transport, media: media, staysWhenAlone: true)
        try await session.connect()
        return ConnectedCall(session: session, media: media, transport: transport)
    }

    private func message(name: String? = nil, sender: String, pinned: Bool, recipient: UInt64 = 0) -> Data {
        NativeMeetFixture.string(1, name ?? messageName) + NativeMeetFixture.string(2, sender)
            + NativeMeetFixture.bytes(5, NativeMeetFixture.string(1, "Agenda"))
            + NativeMeetFixture.number(6, 1) + NativeMeetFixture.number(7, pinned ? 1 : 0)
            + NativeMeetFixture.number(10, recipient)
    }

    private func snapshot(
        _ version: UInt64, messages: [Data], role: UInt64 = 1, state: UInt64 = 1
    ) -> Result<HTTPResponse, any Error> {
        let own = NativeMeetFixture.string(1, local) + NativeMeetFixture.number(4, state)
            + NativeMeetFixture.number(46, role)
        let participant = NativeMeetFixture.string(1, other) + NativeMeetFixture.number(4, 1)
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let roster = metadata + NativeMeetFixture.bytes(2, own) + NativeMeetFixture.bytes(2, participant)
        let full = messages.reduce(into: metadata) { $0 += NativeMeetFixture.bytes(2, $1) }
        return NativeMeetFixture.ok(
            NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, roster))
                + NativeMeetFixture.bytes(3, NativeMeetFixture.bytes(2, full))
        )
    }

    private func reply(
        revision: UInt64,
        pinned: Bool,
        name: String? = nil,
        code: UInt64 = 0,
        sparse: Bool = false
    )
        -> Data {
        var response = NativeMeetFixture.number(1, 1) + NativeMeetFixture.bytes(
            2,
            NativeMeetFixture.number(1, code)
        )
        if !sparse {
            let message = NativeMeetFixture.string(1, name ?? messageName)
                + (pinned ? NativeMeetFixture.number(7, 1) : Data())
            response += NativeMeetFixture.bytes(
                5,
                NativeMeetFixture.bytes(1, message)
                    + NativeMeetFixture.string(5, "\(revision)-version")
            )
        }
        return NativeMeetFixture.bytes(1, response)
    }
}
