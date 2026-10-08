import Foundation

/// A person's calendar status over the next hours: in a meeting, out of
/// office, focus time or busy, each with when it is over (meeting indicator
/// spec §2).
///
/// **The day, not the moment.** A backend sends what it knows, about twelve
/// hours ahead, and a client picks the entry holding "now" and redraws at
/// each boundary. So a meeting starts and ends on time between polls, and
/// after a sleep. Free time is absent: only kinds worth drawing are entries.
///
/// A claim about the near future, like `MemberStatus`: `nil` on a member is
/// "nobody told us", and a schedule that is withdrawn arrives as
/// `.calendarChanged` with `nil`.
public struct CalendarSchedule: Codable, Hashable, Sendable {
    /// One stretch of one kind.
    public struct Entry: Codable, Hashable, Sendable {
        public var start: Date
        public var end: Date
        public var kind: Kind
        /// When it is over by the calendar, which can be later than `end`:
        /// the end of a block of back-to-back meetings, an out-of-office's
        /// return. `nil` when the backend did not say.
        public var until: Date?

        public init(start: Date, end: Date, kind: Kind, until: Date?) {
            self.start = start
            self.end = end
            self.kind = kind
            self.until = until
        }
    }

    /// What the stretch is. Open, like every enum on the wire: a kind a newer
    /// backend sends decodes to `.unknown` and draws nothing.
    public enum Kind: Codable, Hashable, Sendable {
        case inMeeting
        case outOfOffice
        case focusTime
        case busy
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "inMeeting": self = .inMeeting
            case "outOfOffice": self = .outOfOffice
            case "focusTime": self = .focusTime
            case "busy": self = .busy
            default: self = .unknown(wire)
            }
        }

        var wire: String {
            switch self {
            case .inMeeting: "inMeeting"
            case .outOfOffice: "outOfOffice"
            case .focusTime: "focusTime"
            case .busy: "busy"
            case let .unknown(raw): raw
            }
        }

        public init(from decoder: any Decoder) throws {
            try self.init(wire: WireString.decode(from: decoder))
        }

        public func encode(to encoder: any Encoder) throws {
            try WireString.encode(wire, to: encoder)
        }
    }

    /// In order. Only kinds worth drawing; free time is absent.
    public var entries: [Entry]
    /// Nothing is known from here on: no entry is current at or after it.
    public var validUntil: Date?

    public init(entries: [Entry], validUntil: Date?) {
        self.entries = entries
        self.validUntil = validUntil
    }

    /// The entry holding `now`: `start <= now < end`, before `validUntil`.
    public func current(at now: Date) -> Entry? {
        if let validUntil, now >= validUntil {
            return nil
        }
        return entries.first { $0.start <= now && now < $0.end }
    }

    /// Every start, end and `validUntil` after `now`, in order, each once:
    /// the moments at which `current(at:)` can change.
    public func boundaries(after now: Date) -> [Date] {
        let all = entries.flatMap { [$0.start, $0.end] } + [validUntil].compactMap(\.self)
        return Set(all.filter { $0 > now }).sorted()
    }
}

// MARK: - Coding

public extension CalendarSchedule.Entry {
    internal enum CodingKeys: String, CodingKey {
        case start
        case end
        case kind
        case until
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            start: container.decodeWire(Date.self, forKey: .start),
            end: container.decodeWire(Date.self, forKey: .end),
            kind: container.decode(CalendarSchedule.Kind.self, forKey: .kind),
            until: container.decodeWireIfPresent(Date.self, forKey: .until)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWire(start, forKey: .start)
        try container.encodeWire(end, forKey: .end)
        try container.encode(kind, forKey: .kind)
        try container.encodeWireIfPresent(until, forKey: .until)
    }
}

public extension CalendarSchedule {
    internal enum CodingKeys: String, CodingKey {
        case entries
        case validUntil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            entries: container.decode([Entry].self, forKey: .entries),
            validUntil: container.decodeWireIfPresent(Date.self, forKey: .validUntil)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encodeWireIfPresent(validUntil, forKey: .validUntil)
    }
}
