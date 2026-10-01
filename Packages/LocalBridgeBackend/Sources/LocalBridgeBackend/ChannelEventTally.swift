import Foundation
import GChatBridgeCore

/// Every channel event type seen, and the shape of its bodies - the channel
/// half of the in-a-meeting spike (session 32). `--probe=api` asks the
/// `/api/` calls; this watches what the long poll pushes while a meeting
/// starts and ends. The lead is event 45, `USER_HUB_AVAILABILITY_UPDATED_EVENT`,
/// whose payload every vendored proto leaves commented out.
///
/// **Shapes, never values**, the same contract as `APIProbeReport`'s spike
/// section. A body is pblite: a positional array whose index `i` is field
/// `i + 1`, sometimes ending in a dictionary of higher-numbered fields
/// (`ChannelEvent`'s doc comment). A field is its number; an integer of 32
/// or less also shows its value; a nested array or dictionary is expanded a
/// few levels down; a string is `n:s` and never printed. pblite cannot tell a
/// repeated field from a submessage, so an expansion may be either.
struct ChannelEventTally {
    /// How deep a body is expanded.
    static let depth = 4
    /// Distinct shapes kept per type; the rest are counted, not listed.
    static let shapesPerType = 8
    private static let largestOrdinal: Int64 = 32

    struct TypeTally {
        var bodies = 0
        var first: Date
        var last: Date
        var shapes: [String: Int] = [:]
        var otherShapes = 0
    }

    private(set) var types: [Int: TypeTally] = [:]
    /// Bodies with no readable type tag, keyed as -1 in `types`.
    static let untagged = -1

    mutating func record(type: Int?, body: PBLiteValue, at instant: Date) {
        let key = type ?? Self.untagged
        var tally = types[key] ?? TypeTally(first: instant, last: instant)
        tally.bodies += 1
        tally.last = instant
        let shape = Self.shape(of: body, depth: Self.depth)
        if tally.shapes[shape] != nil || tally.shapes.count < Self.shapesPerType {
            tally.shapes[shape, default: 0] += 1
        } else {
            tally.otherShapes += 1
        }
        types[key] = tally
    }

    /// The fields set in a pblite message, in number order.
    static func shape(of value: PBLiteValue, depth: Int) -> String {
        var fields: [(Int, PBLiteValue)] = []
        switch value {
        case let .array(items):
            for (index, item) in items.enumerated() {
                if case let .object(trailing) = item, index == items.count - 1 {
                    fields += numbered(trailing)
                } else if item != .null {
                    fields.append((index + 1, item))
                }
            }
        case let .object(entries):
            fields = numbered(entries)
        default:
            return ""
        }
        return fields.sorted { $0.0 < $1.0 }
            .map { describe(number: $0.0, value: $0.1, depth: depth) }
            .joined(separator: ",")
    }

    private static func numbered(_ entries: [String: PBLiteValue]) -> [(Int, PBLiteValue)] {
        entries.compactMap { key, value in
            guard let number = Int(key), value != .null else { return nil }
            return (number, value)
        }
    }

    private static func describe(number: Int, value: PBLiteValue, depth: Int) -> String {
        switch value {
        case .array, .object:
            guard depth > 0 else { return "\(number){…}" }
            return "\(number){\(shape(of: value, depth: depth - 1))}"
        case .string:
            return "\(number):s"
        case let .number(.integer(integer)) where (0 ... largestOrdinal).contains(integer):
            return "\(number)=\(integer)"
        case .bool, .number:
            return "\(number)"
        case .null:
            return ""
        }
    }

    /// The whole tally as text. `startedAt` and `writtenAt` are local clock
    /// times, so a run can be lined up against when a meeting started.
    func report(startedAt: Date, writtenAt: Date, build: String) -> String {
        var lines = [
            "gchat channel event tally - format 1, shape depth \(Self.depth), build \(build)",
            "started \(Self.clock(startedAt)), written \(Self.clock(writtenAt))",
            ""
        ]
        for type in types.keys.sorted() {
            guard let tally = types[type] else { continue }
            let name = type == Self.untagged
                ? "untagged"
                : Event.EventType(rawValue: type).map { "\($0)" } ?? "not in the proto"
            lines.append(
                "type \(type) (\(name)): \(tally.bodies) bodies, "
                    + "first \(Self.clock(tally.first)), last \(Self.clock(tally.last))"
            )
            for (shape, count) in tally.shapes.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(shape.isEmpty ? "-" : shape): \(count)")
            }
            if tally.otherShapes > 0 {
                lines.append("  other shapes: \(tally.otherShapes)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
