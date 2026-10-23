import Foundation
import LocalBridgeBackend
import Testing
@testable import MacHost

@MainActor
struct NativeCallMediaTests {
    @Test func presentationAudioUsesAnIndependentSenderWithoutRequestingMicrophoneAccess() async throws {
        let media = NativeCallMedia(presentation: true, sharingSystemAudio: true, microphoneAccess: { false })
        let offer = try await media.makeAudioOffer(serverControlChannel: "collections")
        #expect(media.sendsPresentationAudio)
        #expect(!media.isMicrophoneMuted)
        #expect(offer.sdp.contains("a=ssrc:"))
        #expect(offer.sdp.components(separatedBy: "m=audio ").count == 2)
        #expect(media.presentationAudio?.deviceInputSampleRate == 48000)
        #expect(media.presentationAudio?.inputNumberOfChannels == 2)
        media.close()
        #expect(!media.isConnected)
    }

    @Test func deniedMicrophoneDoesNotPrepareAPeerAndCanBeTriedAgain() async {
        let media = NativeCallMedia(microphoneAccess: { false })
        for _ in 0 ..< 2 {
            await #expect(throws: CallMediaError.microphoneDenied) {
                try await media.makeAudioOffer()
            }
            #expect(!media.isConnected)
        }
        media.close()
    }

    @Test func closingWhilePermissionIsPendingRejectsTheLateCompletion() async {
        let gate = MicrophoneGate()
        let media = NativeCallMedia(microphoneAccess: { await gate.wait() })
        let offer = Task { try await media.makeAudioOffer() }
        while gate.continuation == nil {
            await Task.yield()
        }
        await #expect(throws: CallMediaError.busy) { try await media.makeAudioOffer() }
        media.close()
        gate.resume(true)
        await #expect(throws: CallMediaError.closed) { try await offer.value }
        #expect(!media.isConnected)
        await #expect(throws: CallMediaError.closed) { try await media.applyAnswer("not-an-answer") }
    }

    @Test func closedEngineCannotClaimAConnectedTransport() async {
        let media = NativeCallMedia(microphoneAccess: { false })
        media.close()
        media.setMuted(false)
        await #expect(throws: CallMediaError.closed) {
            try await media.waitUntilConnected(timeout: .seconds(1))
        }
        #expect(!media.isConnected)
    }
}

@MainActor
private final class MicrophoneGate {
    var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ permitted: Bool) {
        continuation?.resume(returning: permitted)
        continuation = nil
    }
}
