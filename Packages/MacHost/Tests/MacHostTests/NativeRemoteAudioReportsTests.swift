import Foundation
import Testing
@testable import MacHost

struct NativeRemoteAudioReportsTests {
    private func sample(loss: Int = 2, rtt: Double = 0.040, measurements: Int = 3) -> NativeAudioStatistics {
        var stats = NativeAudioStatistics()
        // Pinned M154 remote-inbound has no packetsReceived/bytesReceived.
        stats.add(type: "remote-inbound-rtp", values: [
            "kind": "audio" as NSString, "packetsLost": loss as NSNumber,
            "roundTripTime": rtt as NSNumber, "roundTripTimeMeasurements": measurements as NSNumber,
            "localId": "private-outbound-reference" as NSString, "fractionLost": 0 as NSNumber
        ])
        return stats
    }

    @Test func remoteReportBlocksHaveSeparatePresenceLossAndRoundTripDiagnostics() {
        let first = sample()
        let second = sample(loss: 4, rtt: 0.050, measurements: 5)
        let lines = second.report(comparedWith: first)
        #expect(lines.contains("Native audio remote RTCP report streams: 1"))
        #expect(lines.contains("Native audio remote RTCP receiver reports: present"))
        #expect(lines.contains("Native audio remote RTCP packets lost total: 4"))
        #expect(lines.contains("Native audio remote RTCP round trip milliseconds: max=50.000"))
        #expect(lines.contains("Native audio remote RTCP round trip measurements: total=5; delta=2"))
        #expect(lines.contains("Native audio inbound streams: 0"))
        #expect(lines.contains("Native audio inbound RTP packets: unavailable"))
        #expect(!lines.joined().contains("private-outbound-reference"))
    }

    @Test func negativeLossIsValidButMissingReportsCannotClaimZeroPackets() {
        #expect(sample(loss: -1).report(comparedWith: sample())
            .contains("Native audio remote RTCP packets lost total: -1"))
        let stats = NativeAudioStatistics()
        let lines = stats.report(comparedWith: stats)
        #expect(lines.contains("Native audio remote RTCP receiver reports: unavailable"))
        #expect(lines.contains("Native audio remote RTCP packets lost total: unavailable"))
        #expect(lines.contains("Native audio remote RTCP round trip milliseconds: unavailable"))
    }

    @Test func videoAndContradictoryTagsNeverCountAsRemoteAudioReports() {
        var stats = NativeAudioStatistics()
        for values: [String: NSObject] in [
            ["kind": "video" as NSString], ["kind": "audio" as NSString, "mediaType": "video" as NSString],
            ["kind": "secret-kind" as NSString], [:]
        ] {
            stats.add(type: "remote-inbound-rtp", values: values)
        }
        #expect(stats.report(comparedWith: stats).contains("Native audio remote RTCP report streams: 0"))
    }

    @Test func malformedAndPartialMetricsCannotInventRemoteReception() {
        for raw in [
            true as NSObject,
            Double.nan as NSNumber,
            Double.infinity as NSNumber,
            1e100 as NSNumber,
            "2" as NSString,
            NSArray(array: [2])
        ] {
            var stats = NativeAudioStatistics()
            stats.add(type: "remote-inbound-rtp", values: [
                "kind": "audio" as NSString, "packetsLost": raw,
                "roundTripTime": raw, "roundTripTimeMeasurements": raw
            ])
            let lines = stats.report(comparedWith: stats)
            #expect(lines.contains("Native audio remote RTCP packets lost total: unavailable"))
            #expect(lines.contains("Native audio remote RTCP round trip milliseconds: unavailable"))
            #expect(lines.contains("Native audio remote RTCP round trip measurements: unavailable"))
        }
        var partial = sample()
        partial.add(type: "remote-inbound-rtp", values: ["kind": "audio" as NSString])
        #expect(partial.report(comparedWith: sample())
            .contains("Native audio remote RTCP packets lost total: unavailable"))
    }

    @Test func changingOrResetRoundTripCountersAreExplicit() {
        #expect(sample(measurements: 1).report(comparedWith: sample())
            .contains("Native audio remote RTCP round trip measurements: total=1; delta=counter reset"))
        #expect(sample().report(comparedWith: NativeAudioStatistics())
            .contains(
                "Native audio remote RTCP round trip measurements: total=3; delta=stream count changed"
            ))
        var overflow = sample(measurements: 9_007_199_254_740_991)
        overflow.add(type: "remote-inbound-rtp", values: [
            "kind": "audio" as NSString, "roundTripTimeMeasurements": 1 as NSNumber
        ])
        #expect(overflow.report(comparedWith: overflow)
            .contains("Native audio remote RTCP round trip measurements: unavailable"))
    }
}
