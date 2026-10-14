import CoreFoundation
import Foundation

/// The pinned SDK creates these records from received remote RTCP report blocks.
/// Their presence does not establish remote playback or a received-packet total.
struct NativeRemoteAudioReports: Sendable {
    private var streamCount = 0
    private var losses = [Double]()
    private var roundTrips = [Double]()
    private var measurements = [Double]()

    mutating func add(_ values: [String: NSObject]) {
        streamCount += 1
        if let loss = NativeDiagnosticNumber.value(values["packetsLost"], integer: true, signed: true),
           (-2_147_483_648 ... 2_147_483_647).contains(loss) {
            losses.append(loss)
        }
        if let rtt = NativeDiagnosticNumber.value(values["roundTripTime"], integer: false),
           rtt <= 3600 {
            roundTrips.append(rtt)
        }
        if let value = NativeDiagnosticNumber.value(values["roundTripTimeMeasurements"], integer: true) {
            measurements.append(value)
        }
    }

    func report(comparedWith first: Self) -> [String] {
        let presence = streamCount > 0 ? "present" : "unavailable"
        let loss = if streamCount > 0, losses.count == streamCount {
            String(format: "%.0f", losses.reduce(0, +))
        } else {
            "unavailable"
        }
        let rtt = if streamCount > 0, roundTrips.count == streamCount, let maximum = roundTrips.max() {
            "max=" + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), maximum * 1000)
        } else {
            "unavailable"
        }
        return [
            "Native audio remote RTCP report streams: \(streamCount)",
            "Native audio remote RTCP receiver reports: \(presence)",
            "Native audio remote RTCP packets lost total: \(loss)",
            "Native audio remote RTCP round trip milliseconds: \(rtt)",
            measurementLine(comparedWith: first)
        ]
    }

    private var measurementTotal: Double? {
        guard streamCount > 0, measurements.count == streamCount else { return nil }
        let sum = measurements.reduce(0, +)
        return sum <= 9_007_199_254_740_991 ? sum : nil
    }

    private func measurementLine(comparedWith first: Self) -> String {
        let prefix = "Native audio remote RTCP round trip measurements: "
        guard let total = measurementTotal else { return prefix + "unavailable" }
        let value = String(format: "%.0f", total)
        guard streamCount == first.streamCount
        else { return prefix + "total=\(value); delta=stream count changed" }
        guard let previous = first.measurementTotal
        else { return prefix + "total=\(value); delta=unavailable" }
        guard total >= previous else { return prefix + "total=\(value); delta=counter reset" }
        return prefix + "total=\(value); delta=" + String(format: "%.0f", total - previous)
    }
}

enum NativeDiagnosticNumber {
    static func value(_ raw: NSObject?, integer: Bool, signed: Bool = false) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        let limit = integer ? 9_007_199_254_740_991.0 : 1_000_000_000.0
        guard value.isFinite, abs(value) <= limit, signed || value >= 0,
              !integer || value.rounded(.towardZero) == value else { return nil }
        return value
    }
}
