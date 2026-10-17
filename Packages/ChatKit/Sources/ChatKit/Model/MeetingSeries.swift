import Foundation

/// A provider-confirmed occurrence of a recurring meeting. `seriesID` is the
/// provider's identity; titles and meeting links are display data and never make
/// two series one. Navigation may still combine same-title series that share a
/// `seriesScope` (`MeetingSeries.build`).
public struct MeetingOccurrence: Codable, Hashable, Sendable {
    public var seriesID: MeetingSeries.ID
    public var occurrenceID: String
    public var seriesTitle: String
    public var scheduledStart: Date
    public var originalStart: Date?
    /// An opaque provider partition, compared only for equality. Same-title
    /// series combine only within one scope; a missing scope matches only
    /// another missing scope.
    public var seriesScope: String?

    public init(
        seriesID: MeetingSeries.ID, occurrenceID: String, seriesTitle: String,
        scheduledStart: Date, originalStart: Date? = nil, seriesScope: String? = nil
    ) {
        self.seriesID = seriesID
        self.occurrenceID = occurrenceID
        self.seriesTitle = seriesTitle
        self.scheduledStart = scheduledStart
        self.originalStart = originalStart
        self.seriesScope = seriesScope
    }

    private enum CodingKeys: String, CodingKey {
        case seriesID, occurrenceID, seriesTitle, scheduledStart, originalStart, seriesScope
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seriesID = try values.decode(MeetingSeries.ID.self, forKey: .seriesID)
        occurrenceID = try values.decode(String.self, forKey: .occurrenceID)
        seriesTitle = try values.decode(String.self, forKey: .seriesTitle)
        scheduledStart = try values.decodeWire(Date.self, forKey: .scheduledStart)
        originalStart = try values.decodeWireIfPresent(Date.self, forKey: .originalStart)
        seriesScope = try values.decodeIfPresent(String.self, forKey: .seriesScope)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(seriesID, forKey: .seriesID)
        try values.encode(occurrenceID, forKey: .occurrenceID)
        try values.encode(seriesTitle, forKey: .seriesTitle)
        try values.encodeWire(scheduledStart, forKey: .scheduledStart)
        try values.encodeWireIfPresent(originalStart, forKey: .originalStart)
        try values.encodeIfPresent(seriesScope, forKey: .seriesScope)
    }

    public var isValid: Bool {
        !seriesID.rawValue.isEmpty && !occurrenceID.isEmpty &&
            !seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            scheduledStart.timeIntervalSince1970.isFinite
    }
}

/// Navigation for same-title recurring meetings within one provider scope,
/// separate from every original chat ID. Build only from the current account's
/// accessible conversation snapshot.
public struct MeetingSeries: Identifiable, Hashable, Sendable {
    public let id: ID
    public let title: String
    public let occurrences: [Conversation]
    public let latest: Conversation

    public var lastActivity: Date? {
        occurrences.compactMap(\.lastActivity).max()
    }

    public static func build(_ conversations: [Conversation]) -> [MeetingSeries] {
        // Orders positions rather than conversation values: this runs for every
        // sidebar and transcript update, and copying whole conversations
        // dominated its cost.
        var parents: [ID: [Entry]] = [:]
        for index in conversations.indices where conversations[index].kind == .meetChat {
            guard let meeting = conversations[index].meeting, meeting.isValid else { continue }
            parents[meeting.seriesID, default: []].append(Entry(
                index: index, conversation: conversations[index].id.rawValue, meeting: meeting
            ))
        }
        // Resolve each provider series' current title and scope first, so a
        // rename does not detach its older occurrences. Recreated series with
        // that exact title and scope share one client conversation within this
        // account snapshot.
        var navigation: [NavigationKey: [Entry]] = [:]
        for entries in parents.values {
            guard let latest = entries.max(by: Entry.precedes) else { continue }
            let key = NavigationKey(
                scope: latest.meeting.seriesScope,
                title: latest.meeting.seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            navigation[key, default: []] += entries
        }
        return navigation.compactMap { key, entries in
            let ordered = entries.sorted(by: Entry.precedes)
            guard let latest = ordered.last else { return nil }
            return MeetingSeries(
                id: key.id, title: latest.meeting.seriesTitle,
                occurrences: ordered.map { conversations[$0.index] }, latest: conversations[latest.index]
            )
        }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private struct Entry {
        let index: Int
        let conversation: String
        let meeting: MeetingOccurrence

        /// Schedule order, with the original chat's ID breaking ties.
        static func precedes(_ left: Self, _ right: Self) -> Bool {
            let start = left.meeting.scheduledStart
            let other = right.meeting.scheduledStart
            return start == other ? left.conversation < right.conversation : start < other
        }
    }

    private struct NavigationKey: Hashable {
        let scope: String?
        let title: String

        /// Unscoped keys keep their original form; a scope is length-prefixed
        /// so no title can produce another scope's key.
        var id: ID {
            scope.map { ID("scoped:\($0.utf8.count):\($0)\(title)") } ?? ID("title:" + title)
        }
    }

    public struct ID: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public init(from decoder: any Decoder) throws {
            try self.init(WireString.decode(from: decoder))
        }

        public func encode(to encoder: any Encoder) throws {
            try WireString.encode(rawValue, to: encoder)
        }
    }
}
