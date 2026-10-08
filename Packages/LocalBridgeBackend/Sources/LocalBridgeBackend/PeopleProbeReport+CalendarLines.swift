import ChatKit
import Foundation
import GChatBridgeCore

/// Whom the section asks about: the local user and the most recent DM
/// partners, labelled, never printed.
struct CalendarProbePeople: Equatable {
    struct Person: Equatable {
        let id: String
        let email: String?
        let label: String
    }

    var me: Person?
    var partners: [Person]
}

/// The calendar section's pure parts: whom to ask, and how an answer is
/// printed. Never a value: labels, member numbers, counts and times relative
/// to the run.
extension PeopleProbeReport {
    /// The local user, and the other member of each DM, most recent first,
    /// each once. Emails come from `get_members`.
    static func calendarPeople(
        conversations: [Conversation],
        members: [ChatKit.Member],
        selfUserID: String?,
        limit: Int
    ) -> CalendarProbePeople {
        let emails = Dictionary(
            members.map { ($0.id.rawValue, $0.email) },
            uniquingKeysWith: { first, _ in first }
        )
        let dms = conversations.filter { $0.kind == .directMessage }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        var ids: [String] = []
        for dm in dms {
            if let other = dm.members.first(where: { $0.rawValue != selfUserID }),
               !ids.contains(other.rawValue) {
                ids.append(other.rawValue)
            }
        }
        let partners = ids.prefix(limit).enumerated().map { index, id in
            CalendarProbePeople.Person(
                id: id,
                email: emails[id].flatMap(\.self),
                label: "person \(index + 1)"
            )
        }
        let me = selfUserID.map {
            CalendarProbePeople.Person(id: $0, email: emails[$0].flatMap(\.self), label: "self")
        }
        return CalendarProbePeople(me: me, partners: partners)
    }

    /// One line per entry, the person by label and the key by its type.
    static func answerLines(_ answer: PeopleStackAnswer, people: CalendarProbePeople, now: Date) -> [String] {
        var labels: [String: String] = [:]
        for person in [people.me].compactMap(\.self) + people.partners {
            labels[person.id] = person.label
            if let email = person.email {
                labels[email.lowercased()] = person.label
            }
        }
        func who(_ key: PeopleStackRequests.Key) -> String {
            let kind = switch key.type {
            case 1: "email"
            case 2: "id"
            default: "type \(key.type)"
            }
            return "\(labels[key.value.lowercased()] ?? "unlisted") (\(kind))"
        }
        func head(_ entry: PeopleStackAnswer.Entry<some Any>) -> String? {
            guard entry.payload == nil || entry.status != nil else { return nil }
            return entry.status.map { "status \($0)" } ?? "ok"
        }
        var lines: [String] = []
        for entry in answer.calendar {
            guard let calendar = entry.payload else {
                lines.append("calendar \(who(entry.key)): \(head(entry) ?? "ok"), no payload")
                continue
            }
            let status = entry.status.map { "status \($0)" } ?? "ok"
            lines.append("calendar \(who(entry.key)): \(status), " + calendarSummary(calendar, now: now))
        }
        for entry in answer.presence {
            lines
                .append("presence \(who(entry.key)): " +
                    (entry.payload.map(String.init) ?? head(entry) ?? "-"))
        }
        for entry in answer.userStatus {
            let value = entry.payload.map { $0 ? "set" : "none" } ?? head(entry) ?? "-"
            lines.append("custom status \(who(entry.key)): " + value)
        }
        return lines
    }

    private static func calendarSummary(_ calendar: PeopleStackCalendarStatus, now: Date) -> String {
        let members = calendar.intervals.map { $0.member.map(String.init) ?? "-" }.joined(separator: " ")
        var parts = ["\(calendar.intervals.count) intervals [\(members)]"]
        if let current = calendar.interval(at: now) {
            let times = current.times.sorted { $0.key < $1.key }.map { field, date in
                "f\(field) " + APIProbeReport.relative(date.timeIntervalSince(now))
            }
            parts.append("now \(current.member.map(String.init) ?? "-") {\(times.joined(separator: ", "))}")
        } else {
            parts.append("now none")
        }
        if let validUntil = calendar.validUntil {
            parts.append("valid until " + APIProbeReport.relative(validUntil.timeIntervalSince(now)))
        }
        parts.append("rows \(calendar.trailingRows)")
        if let context = calendar.intervals.lazy.compactMap(\.contextName).first {
            parts.append("context \(context.count) chars")
        }
        return parts.joined(separator: ", ")
    }

    /// The whole answer as structure: `null`, booleans and integers up to 99
    /// as themselves, a time within 400 days as `now±…`, any other number as
    /// `n<digits>`, a digit string as `d<length>`, any other string as
    /// `s<length>`. Never a value.
    static func maskedShape(_ body: Data, now: Date) -> String {
        var text = String(decoding: body, as: UTF8.self)
        if text.hasPrefix(")]}'") {
            text = String(text.dropFirst(4))
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(text.utf8),
            options: [.fragmentsAllowed]
        )
        else { return "unparsed(\(body.count))" }
        return shape(object, now: now)
    }

    private static func shape(_ value: Any, now: Date) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let array as [Any]:
            return "[" + array.map { shape($0, now: now) }.joined(separator: ",") + "]"
        case let object as [String: Any]:
            let fields = object.sorted { $0.key < $1.key }.map { "s\($0.key.count):" + shape(
                $0.value,
                now: now
            ) }
            return "{" + fields.joined(separator: ",") + "}"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if let integer = Int(exactly: number), (0 ... 99).contains(integer) {
                return String(integer)
            }
            return time(number.doubleValue, now: now) ?? "n\(number.stringValue.count)"
        case let string as String:
            if !string.isEmpty, string.allSatisfy(\.isASCII), string.allSatisfy(\.isNumber) {
                return Double(string).flatMap { time($0, now: now) } ?? "d\(string.count)"
            }
            return "s\(string.count)"
        default:
            return "?"
        }
    }

    /// `value` read as seconds, milliseconds or microseconds, whichever
    /// lands within 400 days of `now`.
    private static func time(_ value: Double, now: Date) -> String? {
        let window = 400.0 * 86400
        let seconds = [value, value / 1000, value / 1_000_000]
            .first { abs($0 - now.timeIntervalSince1970) <= window }
        return seconds.map { APIProbeReport.relative($0 - now.timeIntervalSince1970) }
    }
}
