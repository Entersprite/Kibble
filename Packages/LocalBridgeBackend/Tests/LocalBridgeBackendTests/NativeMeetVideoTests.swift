import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetVideoTests {
    @Test func videoRegistrationCameraToggleAndReceiverBindingShareTheCurrentSession() async throws {
        let media = VideoFakeMedia()
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        let poll = await session.videoPoll
        poll?.cancel()
        _ = await poll?.result
        let announce = try #require(media.announcement)
        #expect(media.requests.count == 2)
        #expect(await session.cameraMuted)
        try await announce(true)
        #expect(await session.cameraMuted == false)
        try await announce(false)
        #expect(await session.cameraMuted)
        media.remoteMuted = false
        await session.refreshVideo()
        #expect(media.answers.count == 2)
        #expect(media.answers.last?.contains("a=ssrc-group:FID 9001 9002") == true)
        #expect(media.visible)
        let requests = media.requests.count
        await session.refreshVideo()
        #expect(media.answers.count == 2)
        #expect(media.requests.count == requests + 1)
        media.remoteMuted = true
        await session.refreshVideo()
        #expect(!media.visible)
        await session.close()
        #expect(media.closed)
        #expect(media.announcement == nil)
        await #expect(throws: (any Error).self) { try await announce(true) }
        #expect(await session.videoContext == nil)
    }

    @Test func unavailableVideoRegistrationKeepsTheJoinedVoiceCallAndNoCameraControls() async throws {
        let media = VideoFakeMedia()
        media.failVideo = true
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        #expect(await session.ready)
        #expect(await session.audioStream != nil)
        #expect(media.announcement == nil)
        #expect(!media.closed)
        await session.close()
    }

    @Test func malformedRemoteSearchHidesVideoWithoutRenegotiatingOrEndingVoice() async throws {
        let media = VideoFakeMedia()
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        let poll = await session.videoPoll
        poll?.cancel()
        _ = await poll?.result
        media.failSearch = true
        await session.refreshVideo()
        #expect(!media.visible)
        #expect(media.answers.count == 1)
        #expect(await session.ready)
        #expect(!media.closed)
        await session.close()
    }

    @Test func failedVideoAnswerRollsBackWithoutClosingVoice() async throws {
        let media = VideoFakeMedia()
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        let poll = await session.videoPoll
        poll?.cancel()
        _ = await poll?.result
        media.failVideoAnswer = true
        await session.refreshVideo()
        #expect(media.rollbacks == 1)
        #expect(media.isConnected)
        #expect(!media.closed)
        #expect(!media.visible)
        #expect(await session.receivingVideo == nil)
        media.failVideoAnswer = false
        await session.refreshVideo()
        #expect(await session.receivingVideo != nil)
        await session.close()
    }

    @Test func repeatedRemotePresentationFallsBackToCameraWithoutReplacingThePeer() async throws {
        let media = VideoFakeMedia()
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        let poll = await session.videoPoll; poll?.cancel(); _ = await poll?.result
        for camera in [false, true, false, true] {
            media.remoteCamera = camera; media.remoteMuted = camera
            await session.refreshVideo()
            #expect(media.remotePresentation == !camera)
            #expect(media.visible == !camera)
            #expect(await session.ready)
        }
        #expect(media.answers.count == 2)
        await session.close()
    }

    @Test func lateOwnPresentationLoopbackIsNotDisplayedAsRemoteMedia() async throws {
        let media = VideoFakeMedia()
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        let poll = await session.videoPoll; poll?.cancel(); _ = await poll?.result
        try await session.rememberPresentationSource(MeetVideoSource(primary: 9001, retransmission: 9002))
        media.remoteMuted = false; media.remoteCamera = false
        await session.refreshVideo()
        #expect(!media.visible)
        #expect(!media.remotePresentation)
        #expect(await session.receivingVideo == nil)
        #expect(media.answers.count == 1)
        await session.close()
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

@MainActor
final class VideoFakeMedia: CallMediaEngine {
    var supportsScreenSharing: Bool {
        true
    }

    var shareStart: (@Sendable (any CallMediaEngine) async throws -> Void)?
    var shareStop: (@Sendable () async -> Bool)?
    var remotePresentation = false
    var remoteCamera = true
    func configureScreenSharing(
        start: (@Sendable (any CallMediaEngine) async throws -> Void)?,
        stop: (@Sendable () async -> Bool)?
    ) {
        shareStart = start; shareStop = stop
    }

    func showRemotePresentation(_ visible: Bool) {
        remotePresentation = visible
    }

    var supportsStreamControl: Bool {
        true
    }

    var supportsVideo: Bool {
        true
    }

    var isConnected = false
    var requests: [Data] = []
    var answers: [String] = []
    var announcement: (@Sendable (Bool) async throws -> Void)?
    var visible = false
    var remoteMuted = true
    var closed = false
    var failVideo = false
    var failSearch = false
    var failVideoAnswer = false
    var rollbacks = 0
    func makeAudioOffer(serverControlChannel _: String?) async throws -> CallAudioOffer {
        let original = try await StreamFakeMedia().makeAudioOffer(serverControlChannel: nil)
        let transport = [
            "a=ice-ufrag:test",
            "a=ice-pwd:nativepassword1234567890",
            "a=fingerprint:sha-256 " + NativeMeetFixture.digest,
            "a=setup:actpass"
        ]
        let codec = ["a=rtpmap:96 VP8/90000", "a=rtpmap:97 rtx/90000", "a=fmtp:97 apt=96"]
        let send = [
            "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
            "a=mid:2",
            "a=sendrecv",
            "a=ssrc:8001 cname:local",
            "a=ssrc:8002 cname:local",
            "a=ssrc-group:FID 8001 8002"
        ] + transport + codec
        let receive = ["m=video 9 UDP/TLS/RTP/SAVPF 96 97", "a=mid:3", "a=recvonly"] + transport + codec
        return CallAudioOffer(
            sdp: original.sdp
                .replacingOccurrences(of: "BUNDLE 0 1", with: "BUNDLE 0 1 2 3") + (send + receive)
                .joined(separator: "\r\n") + "\r\n",
            srtpProfile: .aeadAES256GCM
        )
    }

    func renewVideoOffer() async throws
        -> CallAudioOffer {
        try await makeAudioOffer(serverControlChannel: nil)
    }

    func applyAnswer(_ sdp: String) async throws {
        answers.append(sdp)
    }

    func applyVideoAnswer(_ sdp: String) async throws {
        if failVideoAnswer {
            throw CallMediaError.negotiationFailed
        }
        answers.append(sdp)
    }

    func cancelVideoOffer() async {
        rollbacks += 1
    }

    func waitUntilConnected(timeout _: Duration) async throws {
        isConnected = true
    }

    func setMuted(_: Bool) {}
    func configureCamera(announce: (@Sendable (Bool) async throws -> Void)?) {
        announcement = announce
    }

    func showRemoteVideo(_ visible: Bool) {
        self.visible = visible
    }

    func close() {
        closed = true; isConnected = false
    }

    func exchangeStreamControl(
        _ request: Data,
        matches: @escaping @Sendable (Data) -> Bool,
        timeout _: Duration
    ) async throws -> Data {
        requests.append(request)
        let id = try #require(ProtoFieldScan.varintValues(ofField: 1, in: request).first)
        let variant = try #require(ProtoFieldScan.fields(in: request).fields
            .first { [2, 3, 4].contains($0.number) }?.number)
        let operation = try #require(ProtoFieldScan.payloads(ofField: variant, in: request).first)
        let stream = ProtoFieldScan.payloads(ofField: 4, in: operation).first
        let isVideo = stream.map { ProtoFieldScan.varintValues(ofField: 2, in: $0) == [2] } ?? false
        if isVideo, failVideo {
            throw CallMediaError.signalingTimedOut
        }
        if variant == 3, failSearch {
            return Data([0x80])
        }
        let header = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, 1))
        let result = header +
            (variant == 3 ? NativeMeetFixture.bytes(2, downstream) : stream.map { NativeMeetFixture.bytes(
                4,
                $0
            ) } ?? Data())
        let reply = NativeMeetFixture.number(1, id) + NativeMeetFixture.bytes(4, Data())
            + NativeMeetFixture.bytes(variant == 4 ? 5 : UInt64(variant), result)
        #expect(matches(reply))
        return reply
    }

    private var downstream: Data {
        let pair = NativeMeetFixture.number(2, 9001) + NativeMeetFixture.number(2, 9002)
        let source = NativeMeetFixture.number(1, 9001) + NativeMeetFixture.number(1, 9002)
            + NativeMeetFixture.bytes(2, NativeMeetFixture.string(1, "FID") + pair)
        return NativeMeetFixture.number(1, 1) + NativeMeetFixture.number(2, 2)
            + NativeMeetFixture.string(4, "camera") + NativeMeetFixture.bytes(8, source)
            + NativeMeetFixture.number(11, remoteCamera ? 1 : 0) + NativeMeetFixture.bytes(
                10,
                NativeMeetFixture.number(1, remoteMuted ? 1 : 0)
            )
    }
}
