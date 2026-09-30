import Foundation
import GChatBridgeCore

/// A value-safe decode of fields no proto names (`findings.md` §46.3), for
/// `UserStatus` fields 9 and 10: shaped like a calendar status and a time
/// range, and never decoded past their shape until now.
///
/// **What is printed:**
/// - a varint that is a plausible time (microseconds, milliseconds or seconds
///   since 1970, between 2001 and 2286) becomes the time relative to the run:
///   `3@now-14m`;
/// - a varint of 32 or less is printed as itself (`5=1`), the size of an enum;
/// - any other varint stays `:varint`, because it could be an id;
/// - a byte string becomes a nested shape when it parses cleanly as a message,
///   and otherwise `:text(n)` or `:bytes(n)`: its length, never its content.
///
/// That last rule is load-bearing. Field 9's byte strings may be meeting
/// titles, and the tests pin that one never reaches the report.
extension APIProbeReport {
    private static let largestOrdinal: UInt64 = 32

    static func decodedShape(of data: Data, depth: Int, now: Date) -> String {
        let scan = ProtoFieldScan.fields(in: data)
        var parts: [String] = []
        var varintIndex: [Int: Int] = [:]
        var payloadIndex: [Int: Int] = [:]
        for field in scan.fields {
            switch field.wireType {
            case 0:
                let index = varintIndex[field.number, default: 0]
                varintIndex[field.number] = index + 1
                let values = ProtoFieldScan.varintValues(ofField: field.number, in: data)
                let value = index < values.count ? values[index] : 0
                parts.append("\(field.number)\(describe(varint: value, now: now))")
            case 2:
                let index = payloadIndex[field.number, default: 0]
                payloadIndex[field.number] = index + 1
                let payloads = ProtoFieldScan.payloads(ofField: field.number, in: data)
                let payload = index < payloads.count ? payloads[index] : Data()
                parts.append("\(field.number)\(describe(bytes: payload, depth: depth, now: now))")
            default:
                parts.append("\(field.number):fixed")
            }
        }
        if scan.truncated {
            parts.append("…")
        }
        return parts.joined(separator: ",")
    }

    private static func describe(varint value: UInt64, now: Date) -> String {
        if value <= largestOrdinal {
            return "=\(value)"
        }
        // The same instant in each unit a time could be sent in.
        let candidates = [Double(value) / 1_000_000, Double(value) / 1000, Double(value)]
        let plausible = 978_307_200.0 ... 9_999_999_999.0
        guard let seconds = candidates.first(where: plausible.contains) else { return ":varint" }
        return "@" + relative(seconds - now.timeIntervalSince1970)
    }

    private static func describe(bytes payload: Data, depth: Int, now: Date) -> String {
        if depth > 0, !payload.isEmpty {
            let nested = ProtoFieldScan.fields(in: payload)
            if !nested.truncated, !nested.fields.isEmpty, nested.fields.allSatisfy({ $0.number < 1000 }) {
                return "{\(decodedShape(of: payload, depth: depth - 1, now: now))}"
            }
        }
        let isText = String(data: payload, encoding: .utf8)
            .map { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } } ?? false
        return isText ? ":text(\(payload.count))" : ":bytes(\(payload.count))"
    }

    /// `now-14m`, `now+3h`, `now+4d`: whole units, rounded toward the larger
    /// one only past 90 of the smaller, so a meeting's minutes stay minutes.
    private static func relative(_ interval: TimeInterval) -> String {
        let sign = interval < 0 ? "-" : "+"
        let magnitude = abs(interval)
        let (value, unit): (Double, String) = switch magnitude {
        case ..<90: (magnitude, "s")
        case ..<(90 * 60): (magnitude / 60, "m")
        case ..<(48 * 3600): (magnitude / 3600, "h")
        default: (magnitude / 86400, "d")
        }
        return "now\(sign)\(Int(value.rounded()))\(unit)"
    }

    /// One line per status that carries unnamed fields, numbered in answer
    /// order - never by id - and the local user's labelled `self`.
    static func decodedStatusLines(_ statuses: [UserStatus], selfUserID: String?, now: Date) -> [String] {
        var lines = ["  decoded unnamed fields (times relative to now, text as length only):"]
        var entry = 0
        for status in statuses where !status.unknownFields.data.isEmpty {
            let label: String
            if let selfUserID, status.userID.id == selfUserID {
                label = "self"
            } else {
                entry += 1
                label = "entry \(entry)"
            }
            lines.append("    \(label): \(decodedShape(of: status.unknownFields.data, depth: 3, now: now))")
        }
        if lines.count == 1 {
            lines.append("    none")
        }
        return lines
    }
}
