import ChatKit
import Foundation
import GChatBridgeCore

/// The Calendar instance identity carried by a meeting chat's integration.
/// Parsing stays in the provider; original chat IDs remain message destinations.
enum MeetingMapping {
    static func occurrence(in integrations: [SpaceIntegrationPayload]) -> MeetingOccurrence? {
        let events = integrations.compactMap { integration -> MeetingChatCalendarEvent? in
            guard integration.hasMeetingChat, integration.meetingChat.hasCalendarEvent else { return nil }
            return integration.meetingChat.calendarEvent
        }
        // A warning-only integration may precede the event-bearing integration.
        // Conflicting event records must not silently pick a send destination.
        let occurrences = events.compactMap(occurrence)
        guard let first = occurrences.first,
              occurrences.allSatisfy({ $0 == first }), occurrences.count == events.count else { return nil }
        return first
    }

    private static func occurrence(_ event: MeetingChatCalendarEvent) -> MeetingOccurrence? {
        guard event.hasEventID, event.hasTitle, event.hasStart, event.hasIdentityContext,
              validText(event.title, limit: 4096), validText(event.identityContext, limit: 1024),
              let identity = CalendarMeetingIdentity.parse(event.eventID),
              let scheduled = scheduledStart(event.start),
              let original = identity.originalStart(timeZone: event.start.timeZone) else { return nil }
        // Field7 is kept opaque. Its partition prevents equal event bases in
        // different integration contexts from combining; account scope is owned
        // by the connected backend/store, independently of this metadata.
        let context = event.identityContext
        let key = "calendar:\(context.utf8.count):\(context)\(identity.base)"
        return MeetingOccurrence(
            seriesID: MeetingSeries.ID(key), occurrenceID: event.eventID,
            seriesTitle: event.title, scheduledStart: scheduled, originalStart: original
        )
    }

    private static func scheduledStart(_ value: MeetingChatDateTime) -> Date? {
        guard value.hasTimestamp != value.hasDate else { return nil }
        if value.hasTimestamp {
            let timestamp = value.timestamp
            guard timestamp.hasSeconds, (0 ... 253_402_300_799).contains(timestamp.seconds),
                  (0 ... 999_999_999).contains(timestamp.nanos) else { return nil }
            return Date(timeIntervalSince1970: Double(timestamp.seconds) + Double(timestamp.nanos) / 1e9)
        }
        guard let zone = TimeZone(identifier: value.timeZone) else { return nil }
        return CalendarMeetingIdentity.date(
            year: Int(value.date.year), month: Int(value.date.month), day: Int(value.date.day),
            timeZone: zone
        )
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
