import Foundation
import GChatBridgeCore
import Synchronization
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallInterruptionRecoveryTests {
    @Test func sleepingDoesNotConsumeTheRecoveryGraceAndRepeatedWakesWork() async throws {
        let clock = RecoveryClock()
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media, now: { clock.read() })
        try await session.connect()
        media.isConnected = false
        await session.mediaEvent(.disconnected)
        await session.mediaEvent(.suspended)
        clock.advance(.seconds(3600))
        await session.monitorTick()
        #expect(await session.state == .reconnecting)
        #expect(!media.calls.contains("close"))
        await session.mediaEvent(.resumed)
        clock.advance(.seconds(14))
        await session.monitorTick()
        #expect(!media.calls.contains("close"))
        media.isConnected = true
        await session.mediaEvent(.connected)
        #expect(await session.state == .ready)
        await session.mediaEvent(.suspended)
        clock.advance(.seconds(3600))
        await session.monitorTick()
        await session.mediaEvent(.resumed)
        #expect(await session.state == .ready)
        #expect(!media.calls.contains("close"))
        await session.close()
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("CreateMeetingDevice") }.count == 1)
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
    }

    @Test func unpairedResumeDoesNotExtendTheDisconnectDeadline() async throws {
        let clock = RecoveryClock()
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media, now: { clock.read() })
        try await session.connect()
        media.isConnected = false
        await session.mediaEvent(.disconnected)
        clock.advance(.seconds(10))
        await session.mediaEvent(.resumed)
        clock.advance(.seconds(6))
        await session.monitorTick()
        #expect(await session.state == .ended(.transportFailed))
        await session.mediaEvent(.resumed)
        await session.mediaEvent(.connected)
        #expect(await session.state == .ended(.transportFailed))
        #expect(media.calls.filter { $0 == "close" }.count == 1)
    }
}

private final class RecoveryClock: Sendable {
    private let instant = Mutex<ContinuousClock.Instant>(.now)
    func read() -> ContinuousClock.Instant {
        instant.withLock { $0 }
    }

    func advance(_ duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}
