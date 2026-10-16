import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct SidebarProjectionTests {
    @Test func sortDirectionAppliesBeforeTheCapAndUnknownActivityStaysLast() {
        let rows = [
            Conversation(
                id: .init("a"),
                kind: .space,
                title: "Alpha",
                lastActivity: Date(timeIntervalSince1970: 20)
            ),
            Conversation(
                id: .init("z"),
                kind: .space,
                title: "Zebra",
                lastActivity: Date(timeIntervalSince1970: 10)
            ),
            Conversation(id: .init("n"), kind: .space, title: "Unknown")
        ]
        func ids(_ sort: SidebarSortOrder, _ ascending: Bool) -> [Conversation.ID] {
            SidebarProjection.build(rows, preferences: .init(sections: [
                .init(id: "space", maximumItems: 2, sort: sort, isAscending: ascending)
            ])).first { $0.id == "space" }?.conversations.map(\.id) ?? []
        }
        #expect(ids(.name, true) == [.init("a"), .init("n")])
        #expect(ids(.name, false) == [.init("z"), .init("n")])
        #expect(ids(.activity, true) == [.init("z"), .init("a")])
        #expect(ids(.activity, false) == [.init("a"), .init("z")])
    }

    @Test func groupingPreservesRealKindsAndLimitsAfterActivityOrdering() throws {
        let conversations = (0 ..< 15).map { number in
            Conversation(
                id: .init("\(number)"),
                kind: .directMessage,
                title: "Person \(number)",
                lastActivity: Date(timeIntervalSince1970: Double(number))
            )
        }
        let section = try #require(SidebarProjection.build(conversations, preferences: .init()).first)
        #expect(section.conversations.count == 10)
        #expect(section.conversations.first?.id == Conversation.ID("14"))
        #expect(section.conversations.first?.kind == .directMessage)
        #expect(section.conversations.last?.id == Conversation.ID("5"))
    }

    @Test func appsAndMeetChatsHaveIndependentSectionsAndPreferences() throws {
        let conversations = [
            Conversation(id: .init("dm"), kind: .directMessage),
            Conversation(id: .init("app-a"), kind: .appDirectMessage, title: "Alpha"),
            Conversation(id: .init("app-z"), kind: .appDirectMessage, title: "Zebra"),
            Conversation(id: .init("meet"), kind: .meetChat)
        ]
        let preferences = SidebarPreferences(sections: [
            .init(id: "appDirectMessage", maximumItems: 1, sort: .name),
            .init(id: "directMessage", isVisible: false)
        ])
        let sections = SidebarProjection.build(conversations, preferences: preferences)
        let apps = try #require(sections.first { $0.id == "appDirectMessage" })
        #expect(apps.conversations.map(\.id) == [.init("app-a")])
        #expect(sections.first { $0.id == "meetChat" }?.conversations == [conversations[3]])
        #expect(!sections.contains { $0.id == "directMessage" })
        let full = SidebarProjection.build(conversations, preferences: preferences, limited: false)
        #expect(full.first { $0.id == "appDirectMessage" }?.conversations.count == 2)
    }

    @Test func spacesDefaultToNameAndCanBeSortedByActivity() {
        let spaces = [
            Conversation(
                id: .init("1"),
                kind: .space,
                title: "Zebra",
                lastActivity: Date(timeIntervalSince1970: 20)
            ),
            Conversation(
                id: .init("2"),
                kind: .space,
                title: "Alpha",
                lastActivity: Date(timeIntervalSince1970: 10)
            )
        ]
        let alphabetical = SidebarProjection.build(spaces, preferences: .init()).first { $0.id == "space" }
        #expect(alphabetical?.conversations.first?.title == "Alpha")
        var preferences = SidebarPreferences()
        preferences.update(.init(id: "space", sort: .activity))
        let activity = SidebarProjection.build(spaces, preferences: preferences).first { $0.id == "space" }
        #expect(activity?.conversations.first?.title == "Zebra")
    }

    @Test func hidingReorderingAndLargeLimitsDoNotLoseTheFullList() {
        let preferences = SidebarPreferences(sections: [
            .init(id: "space", maximumItems: Int.max),
            .init(id: "directMessage", isVisible: false),
            .init(id: "space", maximumItems: 1)
        ])
        let sections = SidebarProjection.build([
            Conversation(id: .init("app"), kind: .appDirectMessage),
            Conversation(id: .init("space"), kind: .space)
        ], preferences: preferences)
        #expect(sections.map(\.id) == ["space", "groupDirectMessage", "appDirectMessage", "meetChat"])
        #expect(sections.first?.conversations.count == 1)
        #expect(preferences.orderedSections.count == 5)
    }

    @Test func unknownKindsRemainReachable() {
        let conversation = Conversation(id: .init("future"), kind: .unknown("futureKind"))
        let sections = SidebarProjection.build([conversation], preferences: .init())
        #expect(sections.first?.conversations == [conversation])
    }
}
