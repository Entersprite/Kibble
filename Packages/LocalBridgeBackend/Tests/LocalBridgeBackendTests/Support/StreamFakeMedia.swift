import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
final class StreamFakeMedia: CallMediaEngine {
    var isConnected = false
    var isMicrophoneMuted = false
    var supportsStreamControl: Bool {
        true
    }

    var requests: [Data] = []
    var trackID = "track-sentinel"
    var registrationEchoStreamID: String?
    var failRegistration = false
    var omitEcho = false
    var omitParentContext = false
    var failMute = false
    var holdMute = false
    var closed = false
    var closeCount = 0
    var pending: CheckedContinuation<Void, Never>?

    func makeAudioOffer(serverControlChannel _: String?) async throws -> CallAudioOffer {
        let sdp = NativeMeetFixture.offer.replacingOccurrences(
            of: "a=mid:0\r\n",
            with:
            "a=mid:0\r\na=msid:stream-sentinel \(trackID)\r\na=ssrc:4242 cname:synthetic\r\n"
        )
        return CallAudioOffer(sdp: sdp, srtpProfile: .aeadAES256GCM)
    }

    func applyAnswer(_: String) async throws {}
    func waitUntilConnected(timeout _: Duration) async throws {
        isConnected = true
    }

    func setMuted(_ muted: Bool) {
        isMicrophoneMuted = muted
    }

    func close() {
        closeCount += 1
        closed = true; isConnected = false
    }

    func resume() {
        pending?.resume(); pending = nil
    }

    func exchangeStreamControl(
        _ request: Data, matches: @escaping @Sendable (Data) -> Bool, timeout _: Duration
    ) async throws -> Data {
        requests.append(request)
        let id = try #require(ProtoFieldScan.varintValues(ofField: 1, in: request).first)
        let registering = !ProtoFieldScan.payloads(ofField: 4, in: request).isEmpty
        if !registering, holdMute {
            await withCheckedContinuation { pending = $0 }
        }
        if closed {
            throw CallMediaError.closed
        }
        let operation = try #require(ProtoFieldScan.payloads(ofField: registering ? 4 : 2, in: request).first)
        var stream = try #require(ProtoFieldScan.payloads(ofField: 4, in: operation).first)
        if registering, let registrationEchoStreamID {
            let key = try #require(ProtoFieldScan.payloads(ofField: 4, in: stream).first)
            let original = NativeMeetFixture.bytes(4, key)
            let range = try #require(stream.range(of: original))
            stream.replaceSubrange(range, with: NativeMeetFixture.string(4, registrationEchoStreamID))
        }
        if omitParentContext {
            var sparse = NativeMeetFixture.number(1, 2) + NativeMeetFixture.number(2, 1)
            for field in [4, 8, 10] {
                for payload in ProtoFieldScan.payloads(ofField: field, in: stream) {
                    sparse += NativeMeetFixture.bytes(UInt64(field), payload)
                }
            }
            stream = sparse
        }
        let header = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, 1))
        let status = registering ? failRegistration : failMute
        let reply = NativeMeetFixture.number(1, id) + NativeMeetFixture.bytes(
            4,
            status ? NativeMeetFixture.number(1, 3) : Data()
        )
            + NativeMeetFixture.bytes(
                registering ? 5 : 2, header + (omitEcho ? Data() : NativeMeetFixture.bytes(4, stream))
            )
        #expect(matches(reply))
        return reply
    }
}
