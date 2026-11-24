import Foundation

public struct MeetAgendaGuest: Sendable {
    public enum Response: String, Sendable {
        case needsAction, declined, tentative, accepted
    }

    public let alias: String?
    public let displayName: String
    public let response: Response?
    public let isOptional: Bool
    public let chatAddress: String?
}

enum MeetAgendaGuestWire {
    static func guests(_ event: Data) -> [MeetAgendaGuest] {
        let fields = ProtoFieldScan.fields(in: event).fields
        guard allowsGuests(hiddenValue: 1, field: 28, fields: fields, event: event),
              allowsGuests(hiddenValue: 4, field: 29, fields: fields, event: event) else { return [] }
        let canContact = switch try? MeetProto.value(29, event) {
        case nil, 0, 3: true
        default: false
        }
        var aliases = Set<String>()
        let guests = ProtoFieldScan.payloads(ofField: 14, in: event).prefix(256)
            .compactMap { row -> MeetAgendaGuest? in
                guard let guest = guest(row, canContact: canContact) else { return nil }
                if let alias = guest.alias, !aliases.insert(alias).inserted {
                    return nil
                }
                return guest
            }
        return guests.sorted(by: ordered)
    }

    static func aliases(_ device: Data) -> [String] {
        ProtoFieldScan.payloads(ofField: 43, in: device).prefix(32).compactMap { bytes in
            String(data: bytes, encoding: .utf8).flatMap(alias)
        }
    }

    private static func allowsGuests(
        hiddenValue: UInt64, field: Int, fields: [ProtoField], event: Data
    ) -> Bool {
        guard fields.contains(where: { $0.number == field }) else { return true }
        guard let reason = try? MeetProto.value(field, event) else { return false }
        return reason != hiddenValue
    }

    private static func guest(_ row: Data, canContact: Bool) -> MeetAgendaGuest? {
        let fields = ProtoFieldScan.fields(in: row).fields
        guard isUnset(3, row: row, fields: fields), isUnset(7, row: row, fields: fields) else { return nil }
        let email = (try? MeetProto.text(1, row)).flatMap(alias)
        let name = (try? MeetProto.text(2, row))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayName = name.flatMap({ $0.isEmpty || $0.utf8.count > 512 ? nil : $0 }) ?? email
        else { return nil }
        let response: MeetAgendaGuest.Response? = switch try? MeetProto.value(5, row) {
        case 1: .needsAction
        case 2: .declined
        case 3: .tentative
        case 4: .accepted
        default: nil
        }
        return MeetAgendaGuest(
            alias: email, displayName: displayName, response: response,
            isOptional: (try? MeetProto.value(4, row)) == 1, chatAddress: canContact ? email : nil
        )
    }

    private static func isUnset(_ field: Int, row: Data, fields: [ProtoField]) -> Bool {
        !fields.contains { $0.number == field } || (try? MeetProto.value(field, row)) == 0
    }

    private static func alias(_ value: String) -> String? {
        guard value.utf8.count <= 320, value.utf8.allSatisfy({ (33 ... 126).contains($0) }),
              value.split(separator: "@", omittingEmptySubsequences: false).count == 2,
              value.first != "@", value.last != "@" else { return nil }
        return value.lowercased()
    }

    private static func ordered(_ first: MeetAgendaGuest, _ second: MeetAgendaGuest) -> Bool {
        let firstRank = rank(first.response), secondRank = rank(second.response)
        if firstRank != secondRank {
            return firstRank < secondRank
        }
        if first.isOptional != second.isOptional {
            return !first.isOptional
        }
        return first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
    }

    private static func rank(_ response: MeetAgendaGuest.Response?) -> Int {
        switch response {
        case .accepted: 0
        case .tentative: 1
        case .needsAction, nil: 2
        case .declined: 3
        }
    }
}
