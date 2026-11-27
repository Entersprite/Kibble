import Foundation

/// The web range operation returns expanded events, including moved instances.
/// These values remain in the provider and never become Chat or Meet authority.
public struct CalendarWebOccurrence: Sendable {
    public let identity: String
    public let meetCode: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isOnPrimaryCalendar: Bool
}

enum CalendarWebWire {
    enum Failure: Error {
        case unavailable
        case malformedResponse
    }

    struct Bootstrap {
        let calendars: [String]
        let primary: String
        let securityID: String?
        let uiKind: Int?
        let clientContext: PBLiteValue?
    }

    static func bootstrap(_ body: Data, accountEmail: String) throws -> Bootstrap {
        let html = String(decoding: body, as: UTF8.self)
        guard let marker = html.range(of: "id=\"initialdata\""),
              let start = html[marker.upperBound...].firstIndex(of: ">"),
              let end = html[start...].range(of: "</script>")?.lowerBound,
              let initial = try? JSONDecoder().decode(PBLiteValue.self, from: Data(
                  html[html.index(after: start) ..< end].utf8
              )) else { throw Failure.malformedResponse }
        guard let signedInEmail = initial.field(1)?.field(3)?.stringValue, !signedInEmail.isEmpty else {
            throw Failure.malformedResponse
        }
        guard !accountEmail.isEmpty, accountEmail.utf8.count <= 512,
              signedInEmail.caseInsensitiveCompare(accountEmail) == .orderedSame else {
            throw CalendarWebEventClient.SessionFailure.wrongAccount
        }
        // Initial sync carries calendar-list records and their event detail ACLs.
        let groups = initial.field(40)?.field(2)?.arrayValue ?? []
        var primary = signedInEmail
        var readable: Set<String> = [signedInEmail]
        for entity in groups.flatMap({ $0.field(2)?.arrayValue ?? [] }) {
            guard let record = entity.field(2), let id = record.field(1)?.stringValue,
                  !id.isEmpty, id.utf8.count <= 512 else { continue }
            if record.field(6)?.isTrue == true, id.caseInsensitiveCompare(signedInEmail) == .orderedSame {
                primary = id
            }
            if let access = record.field(4)?.intValue, [2, 3, 4, 6].contains(access) {
                readable.insert(id)
            }
        }
        guard readable.count <= 64 else { throw Failure.unavailable }
        return Bootstrap(
            calendars: readable.sorted(), primary: primary,
            securityID: initial.field(27)?.stringValue.flatMap { $0.utf8.count <= 1024 ? $0 : nil },
            uiKind: initial.field(37)?.intValue,
            clientContext: clientContext(initial)
        )
    }

    /// The Calendar shell supplies the fields the web client uses to describe
    /// its web interface and build when asking for an event range.
    private static func clientContext(_ initial: PBLiteValue) -> PBLiteValue? {
        guard let revision = initial.field(29)?.stringValue, !revision.isEmpty,
              revision.utf8.count <= 512 else {
            return nil
        }
        let clientNumber = initial.field(45)?.stringValue.flatMap(Int32.init) ?? 0
        let label = initial.field(15)?.stringValue.flatMap { $0.utf8.count <= 512 ? $0 : nil }
        return .array([
            nil, 3, label.map(PBLiteValue.string) ?? .null, nil, nil, nil, nil,
            .number(.integer(Int64(clientNumber))), nil, "WEB", .string(revision), 1,
            nil, nil, nil, 1, nil, nil,
            1, 1, nil, 1, 1, nil, 0, 1, 1
        ])
    }

    static func rangeForm(_ bootstrap: Bootstrap, around date: Date) throws -> [(String, String)] {
        guard let context = bootstrap.clientContext else { throw Failure.malformedResponse }
        let unixDay = floor(date.timeIntervalSince1970 / 86400)
        guard (45 ... 2_900_000).contains(unixDay) else { throw Failure.unavailable }
        let day = Int64(unixDay)
        // Range field 2 carries the inclusive first and last UTC calendar days.
        let interval: PBLiteValue = .array([
            .null,
            .null,
            .number(.integer(day - 28)),
            .number(.integer(day + 28))
        ])
        let request: PBLiteValue = .array([.array([
            .array(bootstrap.calendars.map(PBLiteValue.string)), interval, context,
            [nil, 1, 1, 1, 1, nil, 1, 1]
        ])])
        let json = try String(decoding: JSONEncoder().encode(request), as: UTF8.self)
        var fields = [("f.req", json), ("hl", "en")]
        if let uiKind = bootstrap.uiKind {
            fields.append(("cwuik", String(uiKind)))
        }
        if let securityID = bootstrap.securityID {
            fields.append(("secid", securityID))
        }
        return fields
    }

    static func occurrences(
        _ body: Data, bootstrap: Bootstrap, report: @Sendable (String, Int) -> Void
    ) throws -> [CalendarWebOccurrence] {
        let text = String(decoding: body, as: UTF8.self)
        let json: Substring = if text.hasPrefix(")]}'"), let newline = text.firstIndex(of: "\n") {
            text[text.index(after: newline)...]
        } else if text.hasPrefix("while(1);") {
            text.dropFirst("while(1);".count)
        } else {
            text[...]
        }
        let root = try JSONDecoder().decode(PBLiteValue.self, from: Data(json.utf8))
        guard let fields = root.arrayValue?.first?.arrayValue,
              fields.first?.stringValue == "fetcheventrangeaction.ferr" else {
            throw Failure.malformedResponse
        }
        let envelope = PBLiteValue.array(Array(fields.dropFirst()))
        report("range-envelope-status", envelope.field(1)?.intValue ?? -1)
        guard
            let response = envelope.field(2),
            response.arrayValue != nil else { throw Failure.malformedResponse }
        let calendars = Set(bootstrap.calendars)
        var occurrences: [CalendarWebOccurrence] = []
        for group in response.field(2)?.arrayValue ?? [] {
            guard let calendarID = group.field(1)?.stringValue,
                  calendars.contains(calendarID) else { continue }
            for event in group.field(2)?.arrayValue ?? [] {
                if let occurrence = occurrence(event, isPrimary: calendarID == bootstrap.primary) {
                    occurrences.append(occurrence)
                }
                guard occurrences.count <= 4096 else { throw Failure.unavailable }
            }
        }
        return occurrences
    }

    private static func occurrence(_ event: PBLiteValue, isPrimary: Bool) -> CalendarWebOccurrence? {
        guard event.field(2)?.intValue != 2, let id = event.field(1)?.stringValue,
              !id.isEmpty, id.utf8.count <= 512,
              let title = event.field(6)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.utf8.count <= 1024,
              let start = instant(event.field(36)), let end = instant(event.field(37)), end > start,
              let conference = event.field(58), let code = meetingCode(conference) else { return nil }
        let original = instant(event.field(38)) ?? start
        return CalendarWebOccurrence(
            identity: "\(id.utf8.count):\(id):\(original.timeIntervalSince1970)",
            meetCode: code, title: title, start: start, end: end, isOnPrimaryCalendar: isPrimary
        )
    }

    private static func meetingCode(_ conference: PBLiteValue) -> String? {
        let entries = conference.field(1)?.arrayValue ?? []
        var codes = Set(entries.compactMap { entry -> String? in
            guard let address = entry.field(2)?.stringValue,
                  let url = URL(string: address) else { return nil }
            return (try? MeetJoinLink(url))?.code
        })
        if let code = conference.field(10)?.stringValue, code.utf8.count == 12,
           let url = URL(string: "https://meet.google.com/" + code), let link = try? MeetJoinLink(url) {
            codes.insert(link.code)
        }
        return codes.count == 1 ? codes.first : nil
    }

    private static func instant(_ value: PBLiteValue?) -> Date? {
        guard let raw = value?.field(2)?.field(1) ?? value?.field(1),
              let milliseconds = raw.intValue ?? raw.stringValue.flatMap(Int.init),
              (0 ... 253_402_300_799_999).contains(milliseconds) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

private extension PBLiteValue {
    func field(_ number: Int) -> PBLiteValue? {
        if let keyed = objectValue?[String(number)] {
            return keyed.isNull ? nil : keyed
        }
        guard let fields = arrayValue else { return nil }
        if let sparse = fields.last?.objectValue?[String(number)] {
            return sparse.isNull ? nil : sparse
        }
        guard fields.indices.contains(number - 1) else { return nil }
        let value = fields[number - 1]
        return value.isNull ? nil : value
    }

    var isTrue: Bool {
        self == .bool(true) || intValue == 1
    }
}
