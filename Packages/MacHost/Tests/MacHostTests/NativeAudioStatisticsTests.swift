import Foundation
import Testing
@testable import MacHost

struct NativeAudioStatisticsTests {
    private func record(
        _ type: String, kind: String = "audio", packets: Int = 4, bytes: Int = 400,
        energy: Double = 0.4, duration: Double = 2
    ) -> NativeAudioStatistics {
        var result = NativeAudioStatistics()
        result.add(type: type, values: [
            "kind": kind as NSString, "packetsSent": NSNumber(value: packets),
            "bytesSent": NSNumber(value: bytes), "packetsReceived": NSNumber(value: packets),
            "bytesReceived": NSNumber(value: bytes), "totalAudioEnergy": NSNumber(value: energy),
            "totalSamplesDuration": NSNumber(value: duration)
        ])
        return result
    }

    @Test func audioRTPAndCaptureCountersProduceTotalsAndPositiveDeltas() {
        var first = record("inbound-rtp")
        first.add(type: "outbound-rtp", values: [
            "kind": "audio" as NSString, "packetsSent": 5 as NSNumber, "bytesSent": 500 as NSNumber
        ])
        first.add(type: "media-source", values: [
            "kind": "audio" as NSString, "totalAudioEnergy": 0.2 as NSNumber,
            "totalSamplesDuration": 2 as NSNumber
        ])
        var second = record("inbound-rtp", packets: 14, bytes: 1400, energy: 1.4, duration: 3)
        second.add(type: "outbound-rtp", values: [
            "kind": "audio" as NSString, "packetsSent": 15 as NSNumber, "bytesSent": 1500 as NSNumber
        ])
        second.add(type: "media-source", values: [
            "kind": "audio" as NSString, "totalAudioEnergy": 0.4 as NSNumber,
            "totalSamplesDuration": 3 as NSNumber
        ])
        let lines = second.report(comparedWith: first)
        #expect(lines.contains("Native audio inbound RTP packets: total=14; delta=10"))
        #expect(lines.contains("Native audio outbound RTP bytes: total=1500; delta=1000"))
        #expect(lines.contains("Native audio inbound energy change: increased"))
        #expect(lines.contains("Native audio inbound duration delta seconds: 1.000"))
        #expect(lines.contains("Native audio capture energy change: increased"))
        #expect(lines.contains("Native audio capture duration delta seconds: 1.000"))
    }

    @Test func videoRemoteReportsAndConflictingKindsAreExcluded() {
        var stats = NativeAudioStatistics()
        for type in ["inbound-rtp", "outbound-rtp", "media-source"] {
            stats.add(type: type, values: ["kind": "video" as NSString, "packetsSent": 999 as NSNumber])
        }
        stats.add(type: "remote-inbound-rtp", values: ["kind": "audio" as NSString])
        stats.add(type: "track", values: ["kind": "audio" as NSString])
        stats.add(
            type: "inbound-rtp",
            values: ["kind": "audio" as NSString, "mediaType": "video" as NSString]
        )
        let counts = [stats.inbound.count, stats.outbound.count, stats.source.count]
        #expect(counts == [0, 0, 0])
        stats.add(type: "inbound-rtp", values: [
            "mediaType": "audio" as NSString, "packetsReceived": 10 as NSNumber,
            "bytesReceived": 100 as NSNumber
        ])
        #expect(stats.inbound.packetsValue == 10)
    }

    @Test func arbitraryIdentifiersAddressesLevelsAndLabelsNeverEnterTheReport() {
        let sentinel = "private-owner-device-ip-sdp-track-secret"
        var stats = NativeAudioStatistics()
        stats.add(type: "outbound-rtp", values: [
            "kind": "audio" as NSString, "packetsSent": 0 as NSNumber, "bytesSent": 0 as NSNumber,
            "id": sentinel as NSString, "ssrc": sentinel as NSString,
            "trackIdentifier": sentinel as NSString, "ip": sentinel as NSString,
            "audioLevel": sentinel as NSString, "deviceName": sentinel as NSString,
            "totalAudioEnergy": sentinel as NSString
        ])
        stats.add(type: sentinel, values: ["kind": "audio" as NSString])
        let text = stats.report(comparedWith: stats).joined(separator: "\n")
        #expect(!text.contains(sentinel))
        #expect(!text.contains("audioLevel"))
        #expect(!text.contains("trackIdentifier"))
        #expect(text.contains("total=0; delta=0"))
    }

    @Test func malformedNegativeHugeFractionalNaNAndBooleanCountersAreUnavailable() {
        let rejected: [NSObject] = [
            NSNumber(value: -1), NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
            NSNumber(value: 1e100), NSNumber(value: 1.5), NSNumber(value: true), "17" as NSString,
            NSArray(array: [17]), NSDictionary(dictionary: ["value": 17])
        ]
        for value in rejected {
            var stats = NativeAudioStatistics()
            stats.add(type: "outbound-rtp", values: ["kind": "audio" as NSString, "packetsSent": value])
            #expect(stats.outbound.packetsValue == nil)
            #expect(stats.report(comparedWith: stats)
                .contains("Native audio outbound RTP packets: unavailable"))
        }
    }

    @Test func incompleteOrOverflowingAggregatesDoNotClaimZeroTraffic() {
        var stats = record("outbound-rtp")
        stats.add(type: "outbound-rtp", values: ["kind": "audio" as NSString])
        #expect(stats.outbound.packetsValue == nil)
        var overflowing = NativeAudioStatistics()
        for _ in 0 ..< 2 {
            overflowing.add(type: "inbound-rtp", values: [
                "kind": "audio" as NSString, "packetsReceived": NSNumber(value: 9_007_199_254_740_991)
            ])
        }
        #expect(overflowing.inbound.packetsValue == nil)
        var oversized = NativeAudioStatistics()
        let huge = Dictionary(uniqueKeysWithValues: (1 ... 129).map { ("extra\($0)", "secret" as NSObject) })
        oversized.add(type: "inbound-rtp", values: huge)
        #expect(oversized
            .report(comparedWith: stats) == ["Native media statistics: oversized report omitted"])
    }

    @Test func changingStreamCountsCannotClaimIncreasingTrafficOrCaptureEnergy() {
        let first = record("outbound-rtp")
        var second = record("outbound-rtp", packets: 30, bytes: 3000)
        second.add(type: "outbound-rtp", values: [
            "kind": "audio" as NSString, "packetsSent": 10 as NSNumber, "bytesSent": 1000 as NSNumber
        ])
        let lines = second.report(comparedWith: first)
        #expect(lines.contains("Native audio outbound RTP packets: total=40; delta=stream count changed"))
        let sourceLines = record("media-source").report(comparedWith: NativeAudioStatistics())
        #expect(sourceLines.contains("Native audio capture energy change: stream count changed"))
        #expect(sourceLines.contains("Native audio capture duration: stream count changed"))
    }

    @Test func counterResetsAndMissingCaptureSamplesAreExplicit() {
        let first = record("outbound-rtp", packets: 20, bytes: 2000)
        let second = record("outbound-rtp", packets: 4, bytes: 400)
        let lines = second.report(comparedWith: first)
        #expect(lines.contains("Native audio outbound RTP packets: total=4; delta=counter reset"))
        #expect(lines.contains("Native audio capture energy change: unavailable"))
        let missing = NativeAudioStatistics().report(comparedWith: NativeAudioStatistics())
        #expect(missing.contains("Native audio inbound RTP packets: unavailable"))
    }
}
