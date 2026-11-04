import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetCollectionResilienceTests {
    @Test(arguments: [false, true])
    func observingThePeerCompletesRingingDespiteEmptyOrMalformedOptionalCollections(
        _ badPoll: Bool
    ) async throws {
        let responses = NativeMeetFixture.responses(includeInvite: true)
        let replies = Array(responses.prefix(5)) + [snapshot(badPoll: badPoll)]
            + Array(responses.suffix(1))
        let transport = ScriptedTransport(replies), media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        try await session.invite(callee: "peer")
        await session.refreshState()
        #expect(await session.state == .active)
        #expect(await session.device.outgoingInvitationID == nil)
        #expect(media.isConnected)
        #expect(await session.unavailableActivityFields == (badPoll ? [4] : []))
        if badPoll {
            #expect(await !session.activities.availableActions.contains("votePoll"))
            #expect(await session.activities.availableActions.contains("recording"))
        }
        await session.close()
        #expect(await session.state == .ended(.localEnded))
        let requests = await transport.sent
        #expect(!requests.contains { $0.url.path.hasSuffix("CancelMeetingInvite") })
        #expect(requests.filter { $0.url.path.hasSuffix("CreateMeetingInvite") }.count == 1)
        #expect(requests.last?.url.path.hasSuffix("UpdateMeetingDevice") == true)
        let report = await session.takeReport().joined(separator: "\n")
        #expect(!report.contains("collection check unavailable"))
        #expect(!report.contains("spaces/demo") && !report.contains("spaces/foreign"))
        #expect(report.contains("unavailable collection fields 4") == badPoll)
    }

    private func snapshot(badPoll: Bool) -> Result<HTTPResponse, any Error> {
        let own = NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, 1)
        let peer = NativeMeetFixture.string(1, "spaces/demo/devices/peer") + NativeMeetFixture.number(4, 1)
        let devices = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, 8))
            + NativeMeetFixture.bytes(2, own) + NativeMeetFixture.bytes(2, peer)
        let invitation = NativeMeetFixture.string(1, "synthetic-invite") + NativeMeetFixture.number(6, 2)
        var body = collection(2, devices) + collection(
            11,
            NativeMeetFixture.bytes(
                1,
                NativeMeetFixture.number(1, 9)
            ) + NativeMeetFixture.bytes(2, invitation)
        )
        for field in [3, 4, 5, 6, 7, 8, 9, 10] {
            var full = NativeMeetFixture.bytes(1, Data())
            if badPoll, field == 4 {
                full += NativeMeetFixture.bytes(2, NativeMeetFixture.string(1, "spaces/foreign/polls/one"))
            }
            body += collection(UInt64(field), full)
        }
        return NativeMeetFixture.ok(body)
    }

    private func collection(_ field: UInt64, _ full: Data) -> Data {
        NativeMeetFixture.bytes(field, NativeMeetFixture.bytes(2, full))
    }
}
