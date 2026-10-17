import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct MeetingPresentationTests {
    func occurrence(_ id: String, series: String, start: Double) -> Conversation {
        Conversation(
            id: .init(id), kind: .meetChat, title: "Planning - occurrence",
            lastActivity: Date(timeIntervalSince1970: start),
            meeting: MeetingOccurrence(
                seriesID: .init(series), occurrenceID: id, seriesTitle: "Planning",
                scheduledStart: Date(timeIntervalSince1970: start)
            )
        )
    }

    @Test func seriesCountOnceBeforeSidebarCapAndRemainAvailableInSeeAll() throws {
        let first = occurrence("one", series: "parent", start: 100)
        let latest = occurrence("two", series: "parent", start: 200)
        let other = occurrence("three", series: "different-parent", start: 150)
        let oneOff = Conversation(id: .init("four"), kind: .meetChat, title: "One-off")
        let preferences = SidebarPreferences(sections: [.init(id: "meetChat", maximumItems: 1)])
        let section = try #require(SidebarProjection.build(
            [oneOff, other, latest, first], preferences: preferences
        ).first { $0.id == "meetChat" })
        #expect(section.items.map(\.id) == [.meetingSeries(.init("title:Planning"))])
        let all = try #require(SidebarProjection.build(
            [oneOff, other, latest, first], preferences: preferences, limited: false
        ).first { $0.id == "meetChat" })
        #expect(all.items.count == 2)
        if case let .meeting(series) = all.items.first {
            #expect(series.occurrences.count == 3)
        } else {
            Issue.record("Expected the combined recurring meeting first")
        }
        #expect(all.items.map(\.id).contains(.conversation(oneOff.id)))
    }

    @Test func meetingRowUsesLatestMembershipAggregatedActivityAndPerChatUnreadRules() throws {
        var first = occurrence("one", series: "parent", start: 100)
        first.memberCount = 2
        first.hasUnread = true
        first.lastActivity = Date(timeIntervalSince1970: 300)
        var latest = occurrence("two", series: "parent", start: 200)
        latest.memberCount = 12
        let series = try #require(MeetingSeries.build([first, latest]).first)
        var scene = ChatSceneState(conversations: [first, latest])
        let row = ConversationItemRowState(item: .meeting(series), scene: scene)
        #expect(row.title == "Planning")
        #expect(row.detail == "12 members · 2 meetings")
        #expect(row.conversation.id == latest.id)
        #expect(row.lastActivity == first.lastActivity)
        #expect(row.showsUnread)
        scene.unreadHidden = [first.id]
        scene.muted = [latest.id]
        scene.dimmed = [first.id]
        let partiallySuppressed = ConversationItemRowState(item: .meeting(series), scene: scene)
        #expect(!partiallySuppressed.showsUnread && !partiallySuppressed.muted && !partiallySuppressed.dimmed)
        scene.muted.insert(first.id)
        scene.dimmed.insert(latest.id)
        let suppressed = ConversationItemRowState(item: .meeting(series), scene: scene)
        #expect(suppressed.muted && suppressed.dimmed)
    }

    @MainActor
    @Test func groupedHeaderShowsLatestMemberCountAndDirectoryDoesNotBorrowIt() throws {
        var latest = occurrence("one", series: "parent", start: 100)
        latest.memberCount = 12
        let series = try #require(MeetingSeries.build([latest]).first)
        var scene = ChatSceneState(conversations: [latest], selected: latest.id)
        scene.selectedMeetingSeries = series.id
        let actions = ChatSceneActions(select: { _ in }, send: { _ in })
        #expect(ChatWindow(state: scene, actions: actions).subtitle == "12 members")
        scene.browser.page = "meetChat"
        #expect(ChatWindow(state: scene, actions: actions).subtitle.isEmpty)
    }

    @Test func dividersUseScheduleEvenWhenMessagesArriveLateAndNeverCreateMessageRows() {
        let occurrences = [
            occurrence("one", series: "parent", start: 100),
            occurrence("two", series: "parent", start: 200)
        ]
        func message(_ id: String, _ conversation: String, _ timestamp: Double) -> Message {
            Message(
                id: .init(id), conversationID: .init(conversation), threadID: .init(id), sender: .init("me"),
                text: id, createdAt: Date(timeIntervalSince1970: timestamp)
            )
        }
        let messages = [message("a", "one", 101), message("late", "one", 300), message("b", "two", 201)]
        let dividers = MeetingTranscriptPresentation.dividers(messages: messages, occurrences: occurrences)
        #expect(dividers == [
            .init("a"): Date(timeIntervalSince1970: 100),
            .init("b"): Date(timeIntervalSince1970: 200)
        ])
        #expect(messages.count == 3)
    }
}
