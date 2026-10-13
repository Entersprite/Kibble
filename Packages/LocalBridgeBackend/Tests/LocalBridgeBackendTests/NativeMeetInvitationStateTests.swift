import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetInvitationStateTests {
    @Test func declinedOutgoingInvitationClosesOnceWithoutCancellingTheCompletedInvite() async throws {
        let setup = try await setup([snapshot(devices: 8, invitations: 8, status: 7)], completed: true)
        try await setup.session.connect()
        try await setup.session.invite(callee: "peer")
        await setup.session.refreshState()
        #expect(await setup.session.state == .ended(.declined))
        #expect(await setup.session.state.message == "The call was declined.")
        await setup.session.close()
        let sent = await setup.transport.sent
        #expect(sent.count == 7)
        #expect(!sent.contains { $0.url.path.hasSuffix("CancelMeetingInvite") })
        #expect(sent.last?.url.path.hasSuffix("UpdateMeetingDevice") == true)
        #expect(setup.media.calls.filter { $0 == "close" }.count == 1)
        let report = await setup.session.takeReport().joined(separator: "\n")
        #expect(report.contains("device leave settled"))
        #expect(!report.contains("synthetic-invite"))
    }

    @Test func staleAndMissingDeviceSnapshotsCannotTurnDeclineIntoAnEnd() async throws {
        let setup = try await setup([
            snapshot(devices: 8, invitations: 8, status: 2),
            snapshot(devices: 7, invitations: 9, status: 7),
            snapshot(devices: nil, invitations: nil, status: nil),
            snapshot(devices: 8, invitations: nil, status: nil)
        ], completed: true)
        try await setup.session.connect()
        try await setup.session.invite(callee: "peer")
        for _ in 0 ..< 3 {
            await setup.session.refreshState()
            #expect(await setup.session.state == .ringing)
            #expect(!setup.media.calls.contains("close"))
        }
        await setup.session.refreshState()
        #expect(await setup.session.state == .ended(.declined))
    }

    @Test func joinedPeerWinsOverDeclinedStatusInTheSameSnapshot() async throws {
        let setup = try await setup([
            snapshot(devices: 8, invitations: 8, status: 7, peerState: 1),
            snapshot(devices: 9, invitations: 9, status: 7)
        ], completed: true)
        try await setup.session.connect()
        try await setup.session.invite(callee: "peer")
        await setup.session.refreshState()
        #expect(await setup.session.state == .active)
        #expect(!setup.media.calls.contains("close"))
        await setup.session.refreshState()
        #expect(await setup.session.state == .ended(.remoteEnded))
    }

    @Test func anotherConnectingDeviceBlocksDeclineUntilANewerFullDeviceSnapshot() async throws {
        let setup = try await setup([
            snapshot(devices: 8, invitations: 8, status: 7, peerState: 2),
            snapshot(devices: 9, invitations: nil, status: nil)
        ], completed: true)
        try await setup.session.connect()
        try await setup.session.invite(callee: "peer")
        await setup.session.refreshState()
        #expect(await setup.session.state == .ringing)
        await setup.session.refreshState()
        #expect(await setup.session.state == .ended(.declined))
    }

    @Test func foreignStaleUnknownAndMissingStatusesCannotInventADecline() async throws {
        let setup = try await setup([
            snapshot(devices: 8, invitations: 8, status: 7, id: "another-invite"),
            snapshot(devices: 8, invitations: 9, status: 2),
            snapshot(devices: 8, invitations: 8, status: 7),
            snapshot(devices: 8, invitations: 10, status: 99),
            snapshot(devices: 8, invitations: 11, status: nil)
        ], completed: false)
        try await setup.session.connect()
        try await setup.session.invite(callee: "peer")
        for _ in 0 ..< 5 {
            await setup.session.refreshState()
            #expect(await setup.session.state == .ringing)
        }
        await setup.session.close(reason: .ringCancelled)
        #expect(await setup.session.state == .ended(.ringCancelled))
        let sent = await setup.transport.sent
        #expect(sent.filter { $0.url.path.hasSuffix("CancelMeetingInvite") }.count == 1)
    }

    private struct Setup {
        let session: NativeMeetCallSession
        let transport: ScriptedTransport
        let media: NativeFakeMedia
    }

    private func setup(
        _ snapshots: [Result<HTTPResponse, any Error>],
        completed: Bool
    ) async throws -> Setup {
        let responses = NativeMeetFixture.responses(includeInvite: true)
        let replies = Array(responses.prefix(5)) + snapshots + Array(responses.suffix(completed ? 1 : 2))
        let transport = ScriptedTransport(replies)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        return Setup(session: session, transport: transport, media: media)
    }

    private func snapshot(
        devices: UInt64?, invitations: UInt64?, status: UInt64?,
        id: String = "synthetic-invite", peerState: UInt64? = nil
    ) -> Result<HTTPResponse, any Error> {
        var body = Data()
        if let devices {
            var entries = [NativeMeetFixture.string(1, "spaces/demo/devices/one")
                + NativeMeetFixture.number(4, 1)]
            if let peerState {
                entries.append(NativeMeetFixture.string(1, "spaces/demo/devices/peer")
                    + NativeMeetFixture.number(4, peerState))
            }
            body += full(2, version: devices, entries: entries)
        }
        if let invitations {
            var entry = NativeMeetFixture.string(1, id)
            if let status {
                entry += NativeMeetFixture.number(6, status)
            }
            body += full(11, version: invitations, entries: [entry])
        }
        return NativeMeetFixture.ok(body)
    }

    private func full(_ field: UInt64, version: UInt64, entries: [Data]) -> Data {
        let content = entries.reduce(NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))) {
            $0 + NativeMeetFixture.bytes(2, $1)
        }
        return NativeMeetFixture.bytes(field, NativeMeetFixture.bytes(2, content))
    }
}
