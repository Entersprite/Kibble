import Foundation

/// A `GetAssistiveFeatures` answer (`findings.md` §62.6).
public struct PeopleStackAnswer: Sendable, Equatable {
    /// One person's answer for one feature.
    public struct Entry<Payload: Sendable & Equatable>: Sendable, Equatable {
        /// `nil` is ok; 5 is "not found" in the client's code.
        public let status: Int?
        public let key: PeopleStackRequests.Key
        public let payload: Payload?
    }

    public let calendar: [Entry<PeopleStackCalendarStatus>]
    /// The wire's presence value per person.
    public let presence: [Entry<Int>]
    /// Whether a custom status is set, per person.
    public let userStatus: [Entry<Bool>]

    /// `nil` for anything but an answer, an error array included.
    public init?(_ body: Data) {
        var text = String(decoding: body, as: UTF8.self)
        if text.hasPrefix(")]}'") {
            text = String(text.dropFirst(4))
        }
        // An answer's field 1 is a string; an error's is its code.
        guard let top = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              top.first is String
        else { return nil }
        calendar = Self.entries(top, field: 2, PeopleStackCalendarStatus.init)
        presence = Self.entries(top, field: 5) { ($0 as? [Any]).flatMap { Self.element($0, 1) as? Int } }
        userStatus = Self.entries(top, field: 6) { payload in
            (payload as? [Any]).map { (Self.element($0, 1) as? [Any])?.isEmpty == false }
        }
    }

    /// Field `field` (1-based) of `top`: `[[status, "1"], [type, value], payload]` per person.
    private static func entries<Payload>(
        _ top: [Any],
        field: Int,
        _ decode: (Any) -> Payload?
    ) -> [Entry<Payload>] {
        guard let items = element(top, field - 1) as? [Any] else { return [] }
        return items.compactMap { item in
            guard let entry = item as? [Any],
                  let key = element(entry, 1) as? [Any],
                  let type = element(key, 0) as? Int,
                  let value = element(key, 1) as? String
            else { return nil }
            let status = (element(entry, 0) as? [Any]).flatMap { element($0, 0) as? Int }
            return Entry(
                status: status,
                key: PeopleStackRequests.Key(type: type, value: value),
                payload: element(entry, 2).flatMap(decode)
            )
        }
    }

    /// `array[index]`, or `nil` past its end or for JSON `null`.
    static func element(_ array: [Any], _ index: Int) -> Any? {
        guard array.indices.contains(index), !(array[index] is NSNull) else { return nil }
        return array[index]
    }

    /// A `Timestamp`, `[seconds, nanos]`; the seconds are a string, as
    /// int64s are in this encoding, or a number.
    static func date(_ value: Any?) -> Date? {
        guard let parts = value as? [Any] else { return nil }
        let seconds: Double? = switch element(parts, 0) {
        case let text as String: Double(text)
        case let number as NSNumber: number.doubleValue
        default: nil
        }
        // Finite and before the year 5138: anything else is not a time, and
        // would trap whatever prints it.
        guard let seconds, seconds.isFinite, abs(seconds) < 1e11 else { return nil }
        let nanos = (element(parts, 1) as? NSNumber)?.doubleValue ?? 0
        return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
    }
}

extension PeopleStackCalendarStatus {
    /// `[[interval, …], validUntil, [row, …]]`, each interval
    /// `[[start, end], status, context]`.
    init?(_ payload: Any) {
        guard let fields = payload as? [Any] else { return nil }
        let element = PeopleStackAnswer.element
        let items = element(fields, 0) as? [Any] ?? []
        intervals = items.compactMap { item in
            guard let interval = item as? [Any] else { return nil }
            let span = element(interval, 0) as? [Any] ?? []
            let status = element(interval, 1) as? [Any] ?? []
            // A oneof: the first field present is the one set.
            let index = status.indices.first { element(status, $0) != nil }
            var times: [Int: Date] = [:]
            if let index, let message = status[index] as? [Any] {
                for field in message.indices {
                    if let date = PeopleStackAnswer.date(element(message, field)) {
                        times[field + 1] = date
                    }
                }
            }
            let context = element(interval, 2) as? [Any]
            return Interval(
                start: PeopleStackAnswer.date(element(span, 0)),
                end: PeopleStackAnswer.date(element(span, 1)),
                member: index.map { $0 + 1 },
                times: times,
                contextName: context.flatMap { element($0, 2) as? [Any] }
                    .flatMap { element($0, 0) as? String }
            )
        }
        validUntil = PeopleStackAnswer.date(element(fields, 1))
        trailingRows = (element(fields, 2) as? [Any])?.count ?? 0
    }
}

/// A person's calendar status: consecutive intervals, each with its
/// status.
public struct PeopleStackCalendarStatus: Sendable, Equatable {
    public struct Interval: Sendable, Equatable {
        public let start: Date?
        public let end: Date?
        /// Which member of the status oneof is set: 4 out of office,
        /// 5 in a meeting, 6 busy, 7 focus time in the client's code; 2
        /// and 3 have no label there. `nil` when none is.
        public let member: Int?
        /// Every timestamp field of that member's message, by field
        /// number. Which one is the "until" is the code's reading.
        public let times: [Int: Date]
        /// The context's string, the length of an IANA time zone name
        /// in the capture, `[Verify]`.
        public let contextName: String?
    }

    public let intervals: [Interval]
    public let validUntil: Date?
    /// The rows after the intervals, `[1..5, minutes, minutes]` in the
    /// capture: working hours, `[Verify]`.
    public let trailingRows: Int

    /// The interval holding `date`: a start is inclusive, an end is not.
    public func interval(at date: Date) -> Interval? {
        intervals.first { interval in
            guard let start = interval.start, let end = interval.end else { return false }
            return start <= date && date < end
        }
    }
}
