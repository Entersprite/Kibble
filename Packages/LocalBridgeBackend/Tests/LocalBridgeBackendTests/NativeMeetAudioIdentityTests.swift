import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetAudioIdentityTests {
    @Test func repeatedNativeTracksKeepTheProviderMicrophoneKeyAndActualSSRC() async throws {
        let transport = ScriptedTransport(responses() + responses())
        for track in [UUID().uuidString, UUID().uuidString] {
            let media = StreamFakeMedia()
            media.trackID = track
            let offer = try await media.makeAudioOffer(serverControlChannel: nil)
            let source = try MeetAudioOffer(sdp: offer.sdp, collections: true).audioSource()
            #expect(source.streamID == track)
            #expect(source.ssrc == 4242)
            let session = try await NativeMeetFixture.session(transport, media: media)
            try await session.connect()
            #expect(try await session.setMuted(true))
            #expect(try await session.setMuted(false))
            #expect(media.requests.count == 3)
            for (index, request) in media.requests.enumerated() {
                let packet = try stream(in: request, variant: index == 0 ? 4 : 2)
                #expect(ProtoFieldScan.payloads(ofField: 4, in: packet) == [Data("audio".utf8)])
                #expect(ProtoFieldScan.payloads(ofField: 3, in: packet).count == 1)
                #expect(ProtoFieldScan.payloads(ofField: 5, in: packet) == [Data("conference-sentinel".utf8)])
                if index == 0 {
                    let rtp = try #require(ProtoFieldScan.payloads(ofField: 8, in: packet).first)
                    #expect(ProtoFieldScan.payloads(ofField: 1, in: rtp) == [Data([0x92, 0x21])])
                }
            }
            await session.close()
            #expect(media.closed)
        }
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("CreateMediaSession") }.count == 2)
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("CreateMeetingInvite") }.isEmpty)
    }

    @Test func anEchoUsingTheSDPTrackCannotConfirmTheProviderMicrophoneStream() async throws {
        let media = StreamFakeMedia()
        media.registrationEchoStreamID = media.trackID
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        await #expect(throws: CallMediaError.outgoingAudioUnconfirmed) { try await session.connect() }
        #expect(media.closed)
        #expect(await session.audioStream == nil)
        await #expect(throws: MeetDeviceSessionError.notJoined) { try await session.invite(callee: "peer") }
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("stream differs"))
        #expect(!report.contains(media.trackID))
        await session.close()
    }

    private func stream(in request: Data, variant: Int) throws -> Data {
        let operation = try #require(ProtoFieldScan.payloads(ofField: variant, in: request).first)
        return try #require(ProtoFieldScan.payloads(ofField: 4, in: operation).first)
    }

    private func responses() -> [Result<HTTPResponse, any Error>] {
        NativeMeetFixture.responses().map { value in
            value.map { HTTPResponse(
                status: $0.status,
                headers: HTTPHeaders(fields: $0.headers.fields + [.init(
                    name: "X-Goog-Meeting-Debugid", value: "conference-sentinel"
                )]),
                body: $0.body
            ) }
        }
    }
}
