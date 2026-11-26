import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetConferenceEndTests {
    @Test(arguments: [true, false], [true, false])
    func conferenceEndSettlesTheJoinedRegistration(transportFailed: Bool, ended: Bool) async throws {
        let transport = ScriptedTransport(responses(ended: ended))
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media, staysWhenAlone: true)
        try await session.connect()
        await session.refreshState()
        #expect(await session.state == .active)

        if transportFailed {
            await session.mediaEvent(.failed)
        } else {
            await session.refreshState()
        }
        let expected: MeetNativeCallState = ended ? .ended(.conferenceEnded)
            : transportFailed ? .ended(.transportFailed) : .stateUnavailable
        #expect(await session.state == expected)
        if ended {
            #expect(await session.cleanupStatus.isConfirmed)
            #expect(await session.device.localDeviceName == nil)
            #expect(!media.isConnected)
            #expect(await transport.sent.dropFirst(4).map(\.url.lastPathComponent) == [
                "SyncMeetingSpaceCollections", "SyncMeetingSpaceCollections"
            ])
        }
        await session.close()
    }

    @Test(arguments: [true, false])
    func transportRecoveryDuringTheFinalReadPreservesAnExactConferenceEnd(ended: Bool) async throws {
        let base = ScriptedTransport(responses(ended: ended))
        let transport = HeldCollectionTransport(base: base, collectionsBeforeHold: 1)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media, staysWhenAlone: true)
        try await session.connect()
        await session.refreshState()
        #expect(await session.state == .active)
        await session.mediaEvent(.disconnected)
        #expect(await session.state == .reconnecting)

        let failure = Task { await session.mediaEvent(.failed) }
        while await !transport.started {
            await Task.yield()
        }
        await session.mediaEvent(.connected)
        #expect(await session.state == .active)
        await transport.release()
        await failure.value

        #expect(await session.state == (ended ? .ended(.conferenceEnded) : .active))
        #expect(media.isConnected == !ended)
        if ended {
            #expect(await session.cleanupStatus.isConfirmed)
            #expect(await session.device.localDeviceName == nil)
        }
        #expect(await base.sent.dropFirst(4).map(\.url.lastPathComponent) == [
            "SyncMeetingSpaceCollections", "SyncMeetingSpaceCollections"
        ])
        await session.close()
    }

    private func responses(ended: Bool) -> [Result<HTTPResponse, any Error>] {
        let initial = NativeMeetFixture.responses()
        let local = NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, 1)
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, 1))
        let full = NativeMeetFixture.bytes(2, metadata + NativeMeetFixture.bytes(2, local))
        let joined = NativeMeetFixture.ok(NativeMeetFixture.bytes(2, full))
        let message = ended ? "The conference is gone." : "Conference settings are unavailable."
        let status = NativeMeetFixture.number(1, 9) + NativeMeetFixture.string(2, message)
        let refusal: Result<HTTPResponse, any Error> = .success(HTTPResponse(
            status: 400, headers: HTTPHeaders([]), body: status
        ))
        return Array(initial.prefix(4)) + [joined, refusal] + initial.suffix(1)
    }
}
