import Foundation
import GChatBridgeCore
import Synchronization
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetCallStateTests {
    @Test func onlyObservedJoinMakesACallActiveAndLastPeerLeaveClosesItOnce() async throws {
        let replies = [snapshot(1, []), snapshot(2, [("peer", 1)]), snapshot(3, [])]
        let setup = try await setup(replies)
        let session = setup.session
        let transport = setup.transport
        let media = setup.media
        try await session.connect()
        await session.refreshState()
        #expect(await session.state == .ready)
        await session.refreshState()
        #expect(await session.state == .active)
        await session.refreshState()
        #expect(await session.state == .ended(.remoteEnded))
        await session.close()
        #expect(media.calls.filter { $0 == "close" }.count == 1)
        #expect(await transport.sent.count == 8)
        let report = await session.takeReport().joined(separator: "\n")
        #expect(!report.contains("spaces/demo"))
        #expect(!report.contains("40;left"))
    }

    @Test func staleOrUnmodifiedCollectionsAndCheckFailuresCannotInventRemoteHangup() async throws {
        let failure: Result<HTTPResponse, any Error> = .success(HTTPResponse(
            status: 503, headers: HTTPHeaders([]), body: Data()
        ))
        let unchanged = NativeMeetFixture.ok(NativeMeetFixture.bytes(
            2,
            NativeMeetFixture.bytes(1, Data())
        ))
        let setup = try await setup([
            snapshot(8, [("peer", 1)]), snapshot(7, []), unchanged, failure,
            snapshot(8, [("peer", 1)])
        ])
        let session = setup.session
        let media = setup.media
        try await session.connect()
        await session.refreshState()
        #expect(await session.state == .active)
        for _ in 0 ..< 2 {
            await session.refreshState()
        }
        #expect(await session.state == .active)
        await session.refreshState()
        #expect(await session.state == .stateUnavailable)
        #expect(!media.calls.contains("close"))
        await session.refreshState()
        #expect(await session.state == .active)
        await session.close()
    }

    @Test func oneOfSeveralPeerDevicesLeavingDoesNotEndTheCall() async throws {
        let setup = try await setup([
            snapshot(1, [("peerA", 1), ("peerB", 1)]),
            snapshot(2, [("peerA", 6), ("peerB", 1)]), snapshot(3, [("peerA", 6), ("peerB", 6)])
        ])
        let session = setup.session
        let media = setup.media
        try await session.connect()
        await session.refreshState()
        await session.refreshState()
        #expect(await session.state == .active)
        #expect(!media.calls.contains("close"))
        await session.refreshState()
        #expect(await session.state == .ended(.remoteEnded))
    }

    @Test func localDeviceEjectionEndsEvenBeforeAPeerJoins() async throws {
        let setup = try await setup([snapshot(1, [], localState: 7)])
        let session = setup.session
        try await session.connect()
        await session.refreshState()
        #expect(await session.state == .ended(.deviceEnded))
    }

    @Test func mediaLossCanRecoverButFailureClosesWithoutClaimingRemoteHangup() async throws {
        let setup = try await setup([])
        let session = setup.session
        let media = setup.media
        try await session.connect()
        await session.mediaEvent(.disconnected)
        #expect(await session.state == .reconnecting)
        await session.mediaEvent(.connected)
        #expect(await session.state == .ready)
        await session.mediaEvent(.failed)
        #expect(await session.state == .ended(.transportFailed))
        #expect(media.calls.last == "close")
        await session.mediaEvent(.connected)
        #expect(await session.state == .ended(.transportFailed))
    }

    @Test func cancellationWhileSnapshotIsInFlightWaitsBeforeDeviceLeaveAndIgnoresLateState() async throws {
        let replies = Array(NativeMeetFixture.responses().prefix(4)) + [snapshot(1, [("peer", 1)])]
            + Array(NativeMeetFixture.responses().suffix(1))
        let base = ScriptedTransport(replies)
        let transport = HeldCollectionTransport(base: base)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        let refresh = Task { await session.refreshState() }
        while await !transport.started {
            await Task.yield()
        }
        let close = Task { await session.close() }
        while media.calls.last != "close" {
            await Task.yield()
        }
        #expect(await base.sent.count == 5)
        await transport.release()
        await refresh.value
        await close.value
        #expect(await session.state == .ended(.localEnded))
        #expect(await base.sent.count == 6)
    }

    @Test func localRingCancelUsesTheInvitationHandleAndLeavesEvenWhenCancellationFails() async throws {
        var replies = NativeMeetFixture.responses(includeInvite: true)
        replies[5] = .success(HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data()))
        let transport = ScriptedTransport(replies)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        try await session.invite(callee: "peer")
        #expect(await session.state == .ringing)
        await session.close(reason: .ringCancelled)
        await session.close(reason: .ringCancelled)
        let sent = await transport.sent
        #expect(sent.count == 7)
        #expect(sent[5].url.path.hasSuffix("CancelMeetingInvite"))
        #expect(sent[6].url.path.hasSuffix("UpdateMeetingDevice"))
        #expect(await session.state == .endedUnconfirmed(
            .ringCancelled, MeetNativeCallCleanup(invitationUnconfirmed: true)
        ))
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("invitation cancellation unconfirmed"))
        #expect(report.contains("device leave settled"))
    }

    @Test func ringingTimeoutCancelsTheRetainedInvitationAndClosesAudio() async throws {
        let clock = CallTestClock()
        var replies = NativeMeetFixture.responses(includeInvite: true)
        replies.insert(snapshot(1, []), at: 5)
        let transport = ScriptedTransport(replies)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media, now: { clock.read() })
        try await session.connect()
        try await session.invite(callee: "peer")
        clock.advance(.seconds(37))
        await session.monitorTick()
        #expect(await session.state == .ended(.ringingTimedOut))
        #expect(media.calls.last == "close")
        let sent = await transport.sent
        #expect(sent.count == 8)
        #expect(sent[6].url.path.hasSuffix("CancelMeetingInvite"))
        #expect(sent[7].url.path.hasSuffix("UpdateMeetingDevice"))
    }

    @Test func sustainedDisconnectEndsAsTransportFailureAndOldEngineEventsAreIgnored() async throws {
        let clock = CallTestClock()
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media, now: { clock.read() })
        try await session.connect()
        await session.startMonitoring { _ in }
        let handler = try #require(media.eventHandler)
        await handler(.disconnected)
        #expect(await session.state == .reconnecting)
        clock.advance(.seconds(16))
        await session.monitorTick()
        #expect(await session.state == .ended(.transportFailed))
        #expect(media.eventHandler == nil)
        await handler(.connected)
        #expect(await session.state == .ended(.transportFailed))
        #expect(await transport.sent.count == 5)
    }

    @Test func explicitRingWaitsForABackgroundReadInsteadOfLosingTheClickAsBusy() async throws {
        var replies = NativeMeetFixture.responses(includeInvite: true)
        replies.insert(snapshot(1, []), at: 4)
        let base = ScriptedTransport(replies)
        let transport = HeldCollectionTransport(base: base)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        let refresh = Task { await session.refreshState() }
        while await !transport.started {
            await Task.yield()
        }
        let ring = Task { try await session.invite(callee: "peer") }
        while await session.connection == nil {
            await Task.yield()
        }
        #expect(await base.sent.count == 5)
        await transport.release()
        await refresh.value
        try await ring.value
        #expect(await session.state == .ringing)
        await session.close()
        #expect(await base.sent.count == 8)
    }

    @Test func presenterCannotCountAsARemoteParticipantOrKeepAnEndedPeerAlive() async throws {
        func withPresenter(_ version: UInt64, peer: Bool) -> Result<HTTPResponse, any Error> {
            let entries = [("one", ""), ("screen", "one")] + (peer ? [("peer", "")] : [])
            let full = entries.reduce(NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))) {
                $0 + NativeMeetFixture.bytes(
                    2,
                    NativeMeetFixture.string(1, "spaces/demo/devices/" + $1.0)
                        + NativeMeetFixture.number(4, 1)
                        + ($1.1.isEmpty ? Data() : NativeMeetFixture.string(
                            21,
                            "spaces/demo/devices/" + $1.1
                        ))
                )
            }
            return NativeMeetFixture.ok(NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, full)))
        }
        let setup = try await setup([
            withPresenter(1, peer: false),
            withPresenter(2, peer: true),
            withPresenter(3, peer: false)
        ])
        try await setup.session.connect()
        await setup.session.refreshState()
        #expect(await setup.session.state == .ready)
        await setup.session.refreshState()
        #expect(await setup.session.state == .active)
        await setup.session.refreshState()
        #expect(await setup.session.state == .ended(.remoteEnded))
    }

    private struct Setup {
        let session: NativeMeetCallSession
        let transport: ScriptedTransport
        let media: NativeFakeMedia
    }

    private func setup(_ snapshots: [Result<HTTPResponse, any Error>]) async throws
        -> Setup {
        let replies = Array(NativeMeetFixture.responses().prefix(4)) + snapshots
            + Array(NativeMeetFixture.responses().suffix(1))
        let transport = ScriptedTransport(replies)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        return Setup(session: session, transport: transport, media: media)
    }

    private func snapshot(_ version: UInt64, _ peers: [(String, UInt64)], localState: UInt64 = 1)
        -> Result<HTTPResponse, any Error> {
        let values = [("one", localState)] + peers
        let full = values.reduce(NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))) {
            $0 + NativeMeetFixture.bytes(
                2,
                NativeMeetFixture.string(1, "spaces/demo/devices/" + $1.0)
                    + NativeMeetFixture.number(4, $1.1)
            )
        }
        return NativeMeetFixture.ok(NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, full)))
    }
}

private actor HeldCollectionTransport: HTTPTransport {
    let base: ScriptedTransport
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(base: ScriptedTransport) {
        self.base = base
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let result = try await base.send(request)
        if request.url.path.hasSuffix("SyncMeetingSpaceCollections") {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }

    func release() {
        continuation?.resume(); continuation = nil
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }
}

private final class CallTestClock: Sendable {
    private let instant = Mutex<ContinuousClock.Instant>(.now)
    func read() -> ContinuousClock.Instant {
        instant.withLock { $0 }
    }

    func advance(_ duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}
