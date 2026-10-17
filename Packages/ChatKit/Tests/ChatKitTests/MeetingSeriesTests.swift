import Foundation
import Testing
@testable import ChatKit

struct MeetingSeriesTests {
    func occurrence(_ id: String, series: String, start: Double, title: String = "Planning") -> Conversation {
        Conversation(
            id: Conversation.ID(id), kind: .meetChat, title: "\(title) - occurrence",
            meeting: MeetingOccurrence(
                seriesID: MeetingSeries.ID(series), occurrenceID: id, seriesTitle: title,
                scheduledStart: Date(timeIntervalSince1970: start)
            )
        )
    }

    @Test func renamesKeepOlderOccurrencesAndRecreatedSeriesCombineByCurrentTitle() {
        let old = occurrence("old", series: "one", start: 100, title: "Old name")
        var recent = occurrence("recent", series: "one", start: 200, title: "Renamed")
        recent.lastActivity = Date(timeIntervalSince1970: 210)
        var late = old
        late.lastActivity = Date(timeIntervalSince1970: 300)
        let unrelated = occurrence("other", series: "two", start: 100, title: "Renamed")
        let groups = MeetingSeries.build([recent, unrelated, late])
        #expect(groups.count == 1)
        let first = groups.first
        #expect(first?.title == "Renamed")
        #expect(first?.latest.id == recent.id)
        #expect(first?.lastActivity == late.lastActivity)
        #expect(first?.occurrences.map(\.id) == [old.id, unrelated.id, recent.id])
    }

    @Test func threeRecreatedParentsBecomeOneConversationAndOneOffsStaySeparate() throws {
        let counts = [5, 122, 2]
        var conversations: [Conversation] = []
        var time = 0.0
        for (parent, count) in counts.enumerated() {
            for index in 0 ..< count {
                conversations.append(occurrence(
                    "\(parent)-\(index)",
                    series: "parent-\(parent)",
                    start: time
                ))
                time += 100
            }
        }
        conversations += [
            occurrence("different-title", series: "another", start: 0, title: "Engineering"),
            Conversation(id: .init("one-off"), kind: .meetChat, title: "Planning")
        ]
        let groups = MeetingSeries.build(conversations.reversed())
        #expect(groups.count == 2)
        let planning = try #require(groups.first { $0.title == "Planning" })
        #expect(planning.occurrences.count == 129)
        #expect(planning.latest.id == .init("2-1"))
        #expect(Set(planning.occurrences.compactMap { $0.meeting?.seriesID }).count == 3)
        #expect(!planning.occurrences.contains { $0.id == .init("one-off") })
        let withoutRecreatedParent = MeetingSeries.build(Array(conversations.prefix(127)))
        #expect(withoutRecreatedParent.first?.id == planning.id)
    }

    @Test func sameTitleSeriesCombineOnlyWithinOneProviderScope() throws {
        func scoped(_ id: String, series: String, start: Double, scope: String?) -> Conversation {
            var value = occurrence(id, series: series, start: start)
            value.meeting?.seriesScope = scope
            return value
        }
        let first = scoped("a-1", series: "a", start: 100, scope: "team-a")
        let recreated = scoped("a-2", series: "a-recreated", start: 200, scope: "team-a")
        let otherScope = scoped("b-1", series: "b", start: 300, scope: "team-b")
        let unscoped = scoped("u-1", series: "u", start: 400, scope: nil)
        let groups = MeetingSeries.build([first, recreated, otherScope, unscoped])
        #expect(groups.count == 3)
        #expect(Set(groups.map(\.id)).count == 3)
        let combined = try #require(groups.first { $0.latest.id == recreated.id })
        #expect(combined.occurrences.map(\.id) == [first.id, recreated.id])
        #expect(groups.contains { $0.occurrences.map(\.id) == [otherScope.id] })
        let legacy = try #require(groups.first { $0.latest.id == unscoped.id })
        #expect(legacy.occurrences.map(\.id) == [unscoped.id])
        #expect(legacy.id == MeetingSeries.ID("title:Planning"))
    }

    @Test func seriesScopeRoundTripsAndStaysAbsentWhenUnknown() throws {
        var value = occurrence("original", series: "parent", start: 100)
        value.meeting?.seriesScope = "context"
        try expectWireStable(value, golden: "conversation-recurring-meeting-scoped")
        let unscoped = try JSONEncoder().encode(occurrence("original", series: "parent", start: 100))
        let json = try #require(JSONSerialization.jsonObject(with: unscoped) as? [String: Any])
        let metadata = try #require(json["meeting"] as? [String: Any])
        #expect(metadata["seriesScope"] == nil)
    }

    @Test func missingOrInvalidMetadataNeverGroupsAndNonMeetingKindsStaySeparate() {
        let unknown = Conversation(id: Conversation.ID("unknown"), kind: .meetChat, title: "Planning - Oct 2")
        var invalid = occurrence("invalid", series: "", start: 100)
        var human = occurrence("human", series: "one", start: 100)
        human.kind = .directMessage
        #expect(MeetingSeries.build([unknown, invalid, human]).isEmpty)
        invalid.meeting?.seriesID = MeetingSeries.ID("one")
        invalid.meeting?.seriesTitle = " "
        #expect(MeetingSeries.build([invalid]).isEmpty)
    }

    @Test func metadataEventRoundTripsIncludingWithdrawal() throws {
        let value = occurrence("original", series: "parent", start: 100)
        let event = ChatEvent.meetingMetadataChanged(conversationID: value.id, meeting: value.meeting)
        try expectWireStable(event, golden: "event-meeting-metadata")
        try expectWireStable(
            ChatEvent.meetingMetadataLoadingChanged(isLoading: true),
            golden: "event-meeting-metadata-loading"
        )
        let clear = ChatEvent.meetingMetadataChanged(conversationID: value.id, meeting: nil)
        try expectWireStable(clear, golden: "event-meeting-metadata-clear")
    }

    @Test func metadataUsesWireDatesAndOldConversationsDecodeWithoutIt() throws {
        let value = occurrence("original", series: "parent", start: 100)
        try expectWireStable(value, golden: "conversation-recurring-meeting")
        let bytes = try JSONEncoder().encode(value)
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let metadata = try #require(json["meeting"] as? [String: Any])
        #expect(metadata["seriesID"] as? String == "parent")
        #expect(metadata["scheduledStart"] as? String == "1970-01-01T00:01:40.000Z")
        #expect(try JSONDecoder().decode(Conversation.self, from: bytes) == value)
        let old = try JSONDecoder().decode(
            Conversation.self,
            from: Data(#"{"id":"old","kind":"meetChat"}"#.utf8)
        )
        #expect(old.meeting == nil)
    }
}
