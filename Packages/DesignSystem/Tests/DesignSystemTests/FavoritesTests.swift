import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct FavoritesTests {
    @Test func emptyAndUnavailableFavoritesHaveNoSection() {
        let chats = [Conversation(id: .init("chat"), kind: .space)]
        #expect(!SidebarProjection.build(chats, preferences: .init()).contains { $0.id == "favorites" })
        let saved = SidebarPreferences(favoriteConversations: [.init("missing")])
        #expect(!SidebarProjection.build(chats, preferences: saved).contains { $0.id == "favorites" })
    }

    @Test func everyKindIsUnlimitedAndKeepsItsOriginalSection() throws {
        let kinds: [Conversation.Kind] = [
            .directMessage,
            .groupDirectMessage,
            .space,
            .appDirectMessage,
            .meetChat,
            .unknown("future")
        ]
        let chats = (0 ..< 24).map {
            Conversation(
                id: .init("chat-\($0)"),
                kind: kinds[$0 % kinds.count],
                title: "Chat \($0)",
                lastActivity: Date(timeIntervalSince1970: Double($0))
            )
        }
        let preferences = SidebarPreferences(
            sections: [
                .init(id: "space", isVisible: false),
                .init(id: "favorites", isVisible: false, maximumItems: 1)
            ],
            favoriteConversations: Set(chats.map(\.id))
        )
        let sections = SidebarProjection.build(chats, preferences: preferences)
        let favorites = try #require(sections.first)
        #expect(favorites.id == "favorites")
        #expect(favorites.conversations.count == 24)
        #expect(favorites.conversations.first?.id == chats.last?.id)
        #expect(!sections.contains { $0.id == "space" })
        #expect(sections.first { $0.id == "appDirectMessage" }?.conversations.count == 4)
        #expect(favorites.conversations.contains { $0.kind == .space })
    }

    @Test func favoritesApplyBothSortsAndDirections() {
        let chats = [
            Conversation(
                id: .init("a"),
                kind: .space,
                title: "Alpha",
                lastActivity: Date(timeIntervalSince1970: 20)
            ),
            Conversation(
                id: .init("z"),
                kind: .appDirectMessage,
                title: "Zebra",
                lastActivity: Date(timeIntervalSince1970: 10)
            ),
            Conversation(id: .init("n"), kind: .directMessage, title: "Unknown")
        ]
        func ids(_ sort: SidebarSortOrder, _ ascending: Bool) -> [Conversation.ID] {
            SidebarProjection.build(chats, preferences: SidebarPreferences(
                sections: [.init(id: "favorites", sort: sort, isAscending: ascending)],
                favoriteConversations: Set(chats.map(\.id))
            )).first?.conversations.map(\.id) ?? []
        }
        #expect(ids(.name, true) == [.init("a"), .init("n"), .init("z")])
        #expect(ids(.name, false) == [.init("z"), .init("n"), .init("a")])
        #expect(ids(.activity, true) == [.init("z"), .init("a"), .init("n")])
        #expect(ids(.activity, false) == [.init("a"), .init("z"), .init("n")])
    }

    @Test func togglesAreReversibleAndPreserveOtherPreferences() {
        let original = SidebarPreferences(sections: [.init(id: "space", isVisible: false)])
        for target in [SidebarSelection.conversation(.init("chat")), .meetingSeries(.init("series"))] {
            let added = FavoriteMenu.toggling(target, in: original)
            #expect(FavoriteMenu.contains(target, in: added))
            #expect(added.sections == original.sections)
            #expect(FavoriteMenu.toggling(target, in: added) == original)
        }
    }

    @Test func favoriteMeetingIncludesNewOccurrencesWithoutDuplicatingRows() throws {
        func occurrence(_ number: Int) -> Conversation {
            Conversation(
                id: .init("meeting-\(number)"), kind: .meetChat,
                meeting: MeetingOccurrence(
                    seriesID: .init("parent"),
                    occurrenceID: "\(number)",
                    seriesTitle: "Weekly Review",
                    scheduledStart: Date(timeIntervalSince1970: Double(number))
                )
            )
        }
        let first = occurrence(1)
        let series = try #require(MeetingSeries.build([first]).first)
        let preferences = FavoriteMenu.toggling(.meetingSeries(series.id), in: .init())
        let sections = SidebarProjection.build([first, occurrence(2)], preferences: preferences)
        let favorite = try #require(sections.first?.items.first)
        guard case let .meeting(updated) = favorite else { Issue.record("Expected a meeting"); return }
        #expect(updated.occurrences.count == 2)
        #expect(sections.first?.items.count == 1)
        #expect(sections.first { $0.id == "meetChat" }?.items == [favorite])
        let removed = FavoriteMenu.toggling(.meetingSeries(series.id), in: preferences)
        #expect(!SidebarProjection.build([first], preferences: removed).contains { $0.id == "favorites" })
    }
}
