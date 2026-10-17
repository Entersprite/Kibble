import Foundation

/// A provider-confirmed occurrence of a recurring meeting. Titles and meeting
/// links are display data, never evidence that two conversations share a series.
public struct MeetingOccurrence: Codable, Hashable, Sendable {
    public var seriesID: MeetingSeries.ID
    public var occurrenceID: String
    public var seriesTitle: String
    public var scheduledStart: Date
    public var originalStart: Date?

    public init(
        seriesID: MeetingSeries.ID, occurrenceID: String, seriesTitle: String,
        scheduledStart: Date, originalStart: Date? = nil
    ) {
        self.seriesID = seriesID
        self.occurrenceID = occurrenceID
        self.seriesTitle = seriesTitle
        self.scheduledStart = scheduledStart
        self.originalStart = originalStart
    }

    private enum CodingKeys: String, CodingKey {
        case seriesID, occurrenceID, seriesTitle, scheduledStart, originalStart
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seriesID = try values.decode(MeetingSeries.ID.self, forKey: .seriesID)
        occurrenceID = try values.decode(String.self, forKey: .occurrenceID)
        seriesTitle = try values.decode(String.self, forKey: .seriesTitle)
        scheduledStart = try values.decodeWire(Date.self, forKey: .scheduledStart)
        originalStart = try values.decodeWireIfPresent(Date.self, forKey: .originalStart)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(seriesID, forKey: .seriesID)
        try values.encode(occurrenceID, forKey: .occurrenceID)
        try values.encode(seriesTitle, forKey: .seriesTitle)
        try values.encodeWire(scheduledStart, forKey: .scheduledStart)
        try values.encodeWireIfPresent(originalStart, forKey: .originalStart)
    }

    public var isValid: Bool {
        !seriesID.rawValue.isEmpty && !occurrenceID.isEmpty &&
            !seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            scheduledStart.timeIntervalSince1970.isFinite
    }
}

/// Navigation for same-title recurring meetings, separate from every original chat ID.
/// Build only from the current account's accessible conversation snapshot.
public struct MeetingSeries: Identifiable, Hashable, Sendable {
    public let id: ID
    public let title: String
    public let occurrences: [Conversation]
    public let latest: Conversation

    public var lastActivity: Date? {
        occurrences.compactMap(\.lastActivity).max()
    }

    public static func build(_ conversations: [Conversation]) -> [MeetingSeries] {
        let eligible = conversations.compactMap { conversation -> (Conversation, MeetingOccurrence)? in
            guard conversation.kind == .meetChat, let metadata = conversation.meeting,
                  metadata.isValid else { return nil }
            return (conversation, metadata)
        }
        // Resolve each provider series' current title first, so a rename does
        // not detach its older occurrences. Recreated series with that exact
        // title share one client conversation within this account snapshot.
        let providerSeries = Dictionary(grouping: eligible) { $0.1.seriesID }.values.compactMap { items in
            make(items, id: items[0].1.seriesID)
        }
        let byTitle = Dictionary(grouping: providerSeries) {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return byTitle.compactMap { title, series in
            let items = series.flatMap(\.occurrences).compactMap { conversation in
                conversation.meeting.map { (conversation, $0) }
            }
            return make(items, id: ID("title:" + title))
        }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func make(_ items: [(Conversation, MeetingOccurrence)], id: ID) -> MeetingSeries? {
        let ordered = items.sorted {
            let left = $0.1.scheduledStart
            let right = $1.1.scheduledStart
            return left == right ? $0.0.id.rawValue < $1.0.id.rawValue : left < right
        }
        guard let latest = ordered.last else { return nil }
        return MeetingSeries(
            id: id, title: latest.1.seriesTitle, occurrences: ordered.map(\.0), latest: latest.0
        )
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
