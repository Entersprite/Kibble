import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The other person's microphone, read from the stream search the call already
/// runs every two seconds, and published beside the call state.
@MainActor
struct NativeMeetRemoteAudioTests {
    @MainActor
    final class Recorder {
        var values: [Bool?] = []
    }

    @Test func eachSearchPublishesTheRemoteMicrophoneOnlyWhenItChanges() async throws {
        let media = VideoFakeMedia()
        let session = try await connectedSession(media)
        let recorder = Recorder()
        await session.startMonitoring(receive: { _ in }, remoteMuted: { value in
            await MainActor.run { recorder.values.append(value) }
        })
        media.remoteMuted = false
        media.remoteAudio = [1]
        await session.refreshVideo()
        #expect(await session.remoteAudioMuted == true)
        await session.refreshVideo()
        media.remoteAudio = [0]
        await session.refreshVideo()
        // Ambiguous, absent and missing entries are unknown, never muted.
        media.remoteAudio = [1, 1]
        await session.refreshVideo()
        media.remoteAudio = [1]
        await session.refreshVideo()
        media.remoteAudio = [nil]
        await session.refreshVideo()
        media.remoteAudio = [1]
        await session.refreshVideo()
        media.remoteAudio = []
        await session.refreshVideo()
        #expect(recorder.values == [true, false, nil, true, nil, true, nil])
        // The camera selection is the same one it was without audio entries.
        #expect(media.visible)
        #expect(media.answers.count == 2)
        await session.close()
    }

    @Test func aFailedSearchForgetsTheLastValueRatherThanKeepingItsBadge() async throws {
        let media = VideoFakeMedia()
        let session = try await connectedSession(media)
        media.remoteAudio = [1]
        await session.refreshVideo()
        #expect(await session.remoteAudioMuted == true)
        media.failSearch = true
        await session.refreshVideo()
        #expect(await session.remoteAudioMuted == nil)
        media.failSearch = false
        await session.refreshVideo()
        #expect(await session.remoteAudioMuted == true)
        // A search that never answers is unknown too.
        media.timeOutSearch = true
        await session.refreshVideo()
        #expect(await session.remoteAudioMuted == nil)
        #expect(await session.ready)
        await session.close()
    }

    @Test func theAudioOnlyPollForgetsTheValueWhenItsSearchFails() async throws {
        let media = VideoFakeMedia()
        media.failVideo = true
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        let poll = await session.videoPoll
        poll?.cancel()
        _ = await poll?.result
        media.remoteAudio = [1]
        await session.refreshRemoteAudio()
        #expect(await session.remoteAudioMuted == true)
        media.timeOutSearch = true
        await session.refreshRemoteAudio()
        #expect(await session.remoteAudioMuted == nil)
        await session.close()
    }

    @Test func aValueReadBeforeMonitoringStartsIsDeliveredWhenItDoes() async throws {
        let media = VideoFakeMedia()
        let session = try await connectedSession(media)
        media.remoteAudio = [1]
        await session.refreshVideo()
        let recorder = Recorder()
        await session.startMonitoring(receive: { _ in }, remoteMuted: { value in
            await MainActor.run { recorder.values.append(value) }
        })
        #expect(recorder.values == [true])
        await session.close()
    }

    @Test func aClosedCallPublishesNothingFurther() async throws {
        let media = VideoFakeMedia()
        let session = try await connectedSession(media)
        let recorder = Recorder()
        await session.startMonitoring(receive: { _ in }, remoteMuted: { value in
            await MainActor.run { recorder.values.append(value) }
        })
        await session.close()
        media.remoteAudio = [1]
        await session.refreshVideo()
        await session.refreshRemoteAudio()
        #expect(recorder.values.isEmpty)
        #expect(await session.remoteAudioMuted == nil)
    }

    @Test func unavailableCameraRegistrationStillPollsTheRemoteMicrophone() async throws {
        let media = VideoFakeMedia()
        media.failVideo = true
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        #expect(media.announcement == nil)
        #expect(await session.videoContext == nil)
        let poll = try #require(await session.videoPoll)
        poll.cancel()
        _ = await poll.result
        media.remoteAudio = [1]
        await session.refreshRemoteAudio()
        #expect(await session.remoteAudioMuted == true)
        #expect(media.searches == 1)
        // Audio only: no receiving video is negotiated or shown.
        #expect(media.answers.count == 1)
        #expect(!media.visible)
        await session.close()
        #expect(await session.videoPoll == nil)
    }

    @Test func theAudioOnlyPollIsNotStartedBesideTheVideoPoll() async throws {
        let media = VideoFakeMedia()
        let session = try await connectedSession(media)
        // With video registered, refreshRemoteAudio is not the poll's job.
        media.remoteAudio = [1]
        await session.refreshRemoteAudio()
        #expect(media.searches == 0)
        #expect(await session.remoteAudioMuted == nil)
        await session.close()
    }

    private func connectedSession(_ media: VideoFakeMedia) async throws -> NativeMeetCallSession {
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        let poll = await session.videoPoll
        poll?.cancel()
        _ = await poll?.result
        return session
    }

    private func responses() -> [Result<HTTPResponse, any Error>] {
        NativeMeetFixture.responses(video: true).map { value in
            value.map { HTTPResponse(
                status: $0.status,
                headers: HTTPHeaders(fields: $0.headers.fields + [.init(
                    name: "X-Goog-Meeting-Debugid",
                    value: "conference"
                )]),
                body: $0.body
            ) }
        }
    }
}
