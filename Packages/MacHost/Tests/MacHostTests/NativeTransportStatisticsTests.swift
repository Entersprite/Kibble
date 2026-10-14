import Foundation
import Testing
@testable import MacHost

struct NativeTransportStatisticsTests {
    @Test func negotiatedCipherUsesPinnedSDKNamesAndDoesNotRequireAnAudioKind() {
        var stats = NativeAudioStatistics()
        stats.add(type: "transport", values: [
            "srtpCipher": "SRTP_AEAD_AES_256_GCM" as NSString, "tlsVersion": "FEFD" as NSString
        ])
        let lines = stats.report(comparedWith: stats)
        #expect(lines.contains("Native media transport records: 1"))
        #expect(lines.contains("Native media negotiated SRTP: matches advertised AES-256-GCM"))
        #expect(lines.contains("Native media negotiated TLS version: DTLS 1.2"))
        for cipher in [
            "SRTP_AEAD_AES_128_GCM",
            "SRTP_AES128_CM_HMAC_SHA1_80",
            "SRTP_AES128_CM_HMAC_SHA1_32"
        ] {
            var different = NativeTransportStatistics()
            different.add(["srtpCipher": cipher as NSString])
            #expect(different.report().contains("Native media negotiated SRTP: different supported cipher"))
        }
    }

    @Test func unknownMalformedAndMixedTransportValuesRemainFixedLabels() {
        let secret = "secret-address-certificate-transport"
        for raw in [secret as NSObject, true as NSNumber, NSArray(array: [secret])] {
            var stats = NativeTransportStatistics()
            stats.add(["srtpCipher": raw, "tlsVersion": raw, "id": secret as NSString])
            let text = stats.report().joined(separator: "\n")
            #expect(text.contains("SRTP: unavailable"))
            #expect(!text.contains(secret))
        }
        var mixed = NativeTransportStatistics()
        mixed.add(["srtpCipher": "SRTP_AEAD_AES_256_GCM" as NSString])
        mixed.add([:])
        let lines = mixed.report()
        #expect(lines.contains("Native media negotiated SRTP: mixed transport results"))
    }

    @Test func localAudioSourceParsingAndComparisonExportOnlyTheMatch() {
        let sdp = "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ssrc:4189 cname:secret\r\n"
            + "a=ssrc:4189 msid:private-stream private-track\r\n"
            + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
        #expect(NativeAudioSourceMatch.localAudioSSRC(sdp) == 4189)
        var stats = NativeAudioStatistics()
        stats.add(
            type: "outbound-rtp",
            values: ["kind": "audio" as NSString, "ssrc": 4189 as NSNumber],
            localAudioSSRC: NativeAudioSourceMatch.localAudioSSRC(sdp)
        )
        let text = stats.report(comparedWith: stats).joined(separator: "\n")
        #expect(text.contains("source matches local offer: matches"))
        #expect(!text.contains("4189"))
        #expect(!text.contains("private-stream"))
        var mismatch = NativeAudioSourceMatch()
        mismatch.add(4190 as NSNumber, expected: 4189)
        #expect(mismatch.report() == ["Native audio outbound source matches local offer: mismatch"])
    }

    @Test func ambiguousMissingMalformedAndOversizedSourceComparisonsAreUnavailable() {
        for sdp in [
            "m=video 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:4189 cname:x",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:0 cname:x",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:4189 cname:x\na=ssrc:4190 cname:y",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:4189 cname:x\nm=audio 9 UDP/TLS/RTP/SAVPF 111",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:4189", String(repeating: "a", count: 100_000)
        ] {
            #expect(NativeAudioSourceMatch.localAudioSSRC(sdp) == nil)
        }
        for raw in [
            true as NSObject,
            -1 as NSNumber,
            1.5 as NSNumber,
            Double.nan as NSNumber,
            4_294_967_296 as NSNumber,
            "4189" as NSString
        ] {
            var match = NativeAudioSourceMatch()
            match.add(raw, expected: 4189)
            #expect(match.report() == ["Native audio outbound source matches local offer: unavailable"])
        }
    }
}
