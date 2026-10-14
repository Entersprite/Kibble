import CoreFoundation
import Foundation

/// The only statistics allowed into a media diagnostic. Raw SDK reports,
/// stream identifiers, addresses and instantaneous audio levels stay outside.
struct NativeAudioStatistics: Sendable {
    static let maximumRecords = 2048
    var inbound = AudioBucket()
    var outbound = AudioBucket()
    var source = AudioBucket()
    var remote = NativeRemoteAudioReports()
    var transport = NativeTransportStatistics()
    var sourceMatch = NativeAudioSourceMatch()
    var isBounded = true

    mutating func add(type: String, values: [String: NSObject], localAudioSSRC: UInt32? = nil) {
        guard values.count <= 128 else { isBounded = false; return }
        if type == "transport" {
            transport.add(values)
            return
        }
        guard Self.isAudio(values) else { return }
        switch type {
        case "inbound-rtp": inbound.add(values, packets: "packetsReceived", bytes: "bytesReceived")
        case "outbound-rtp":
            outbound.add(values, packets: "packetsSent", bytes: "bytesSent")
            sourceMatch.add(values["ssrc"], expected: localAudioSSRC)
        case "media-source": source.add(values, packets: nil, bytes: nil)
        case "remote-inbound-rtp": remote.add(values)
        default: break
        }
    }

    private static func isAudio(_ values: [String: NSObject]) -> Bool {
        let kind = values["kind"] as? String
        let legacy = values["mediaType"] as? String
        guard kind == "audio" || (kind == nil && legacy == "audio") else { return false }
        return legacy == nil || legacy == "audio"
    }

    func report(comparedWith first: NativeAudioStatistics) -> [String] {
        guard isBounded, first.isBounded else { return ["Native media statistics: oversized report omitted"] }
        let sameInbound = inbound.count == first.inbound.count
        let sameOutbound = outbound.count == first.outbound.count
        let sameSource = source.count == first.source.count
        return transport.report() + sourceMatch.report() + remote.report(comparedWith: first.remote) + [
            "Native audio inbound streams: \(inbound.count)",
            "Native audio outbound streams: \(outbound.count)",
            "Native audio capture sources: \(source.count)",
            Self.counterLine(
                "inbound RTP packets",
                first.inbound.packetsValue,
                inbound.packetsValue,
                sameInbound
            ),
            Self.counterLine("inbound RTP bytes", first.inbound.bytesValue, inbound.bytesValue, sameInbound),
            Self.counterLine(
                "outbound RTP packets",
                first.outbound.packetsValue,
                outbound.packetsValue,
                sameOutbound
            ),
            Self.counterLine(
                "outbound RTP bytes",
                first.outbound.bytesValue,
                outbound.bytesValue,
                sameOutbound
            ),
            "Native audio inbound energy change: "
                + Self.change(first.inbound.energyValue, inbound.energyValue, sameInbound),
            Self.durationLine("inbound", first.inbound.durationValue, inbound.durationValue, sameInbound),
            "Native audio capture energy change: "
                + Self.change(first.source.energyValue, source.energyValue, sameSource),
            Self.durationLine("capture", first.source.durationValue, source.durationValue, sameSource)
        ]
    }

    private static func counterLine(
        _ label: String, _ first: Double?, _ second: Double?, _ sameCount: Bool
    ) -> String {
        guard let second else { return "Native audio \(label): unavailable" }
        let total = String(format: "%.0f", second)
        guard sameCount else { return "Native audio \(label): total=\(total); delta=stream count changed" }
        guard let first else { return "Native audio \(label): total=\(total); delta=unavailable" }
        guard second >= first else { return "Native audio \(label): total=\(total); delta=counter reset" }
        let delta = String(format: "%.0f", second - first)
        return "Native audio \(label): total=\(total); delta=\(delta)"
    }

    private static func durationLine(
        _ label: String, _ first: Double?, _ second: Double?, _ sameCount: Bool
    ) -> String {
        guard sameCount else { return "Native audio \(label) duration: stream count changed" }
        guard let first, let second else { return "Native audio \(label) duration: unavailable" }
        guard second >= first else { return "Native audio \(label) duration: counter reset" }
        let seconds = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), second - first)
        return "Native audio \(label) duration delta seconds: \(seconds)"
    }

    private static func change(_ first: Double?, _ second: Double?, _ sameCount: Bool) -> String {
        guard sameCount else { return "stream count changed" }
        guard let first, let second else { return "unavailable" }
        if second < first {
            return "counter reset"
        }
        return second > first ? "increased" : "unchanged"
    }
}

extension NativeAudioStatistics {
    struct AudioBucket: Sendable {
        var count = 0
        private var packets = Metric()
        private var bytes = Metric()
        private var energy = Metric()
        private var duration = Metric()

        var packetsValue: Double? {
            packets.value(expected: count)
        }

        var bytesValue: Double? {
            bytes.value(expected: count)
        }

        var energyValue: Double? {
            energy.value(expected: count)
        }

        var durationValue: Double? {
            duration.value(expected: count)
        }

        mutating func add(_ values: [String: NSObject], packets packetKey: String?, bytes byteKey: String?) {
            count += 1
            if let packetKey {
                packets.add(values[packetKey], integer: true)
            }
            if let byteKey {
                bytes.add(values[byteKey], integer: true)
            }
            energy.add(values["totalAudioEnergy"], integer: false)
            duration.add(values["totalSamplesDuration"], integer: false)
        }
    }

    private struct Metric: Sendable {
        private var sum = 0.0
        private var present = 0
        private var rejected = false

        mutating func add(_ raw: NSObject?, integer: Bool) {
            guard let raw else { return }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                rejected = true
                return
            }
            let value = number.doubleValue
            let limit = integer ? 9_007_199_254_740_991.0 : 1_000_000_000.0
            guard value.isFinite, value >= 0, value <= limit,
                  !integer || value.rounded(.towardZero) == value else {
                rejected = true
                return
            }
            sum += value
            present += 1
            if !sum.isFinite || sum > limit {
                rejected = true
            }
        }

        func value(expected: Int) -> Double? {
            guard expected > 0, present == expected, !rejected else { return nil }
            return sum
        }
    }
}
