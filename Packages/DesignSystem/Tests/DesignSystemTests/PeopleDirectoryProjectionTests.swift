import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct PeopleDirectoryProjectionTests {
    @Test func oneSearchCombinesLocalAndRemoteMatchesWithoutDuplicatesOrApps() {
        let local = Member(id: .init("local"), kind: .human, displayName: "Local Ava")
        let remote = Member(id: .init("remote"), kind: .human, displayName: "Remote Ava")
        let bot = Member(id: .init("bot"), kind: .app, displayName: "Ava App")
        let unrelated = Member(id: .init("other"), kind: .human, displayName: "Zoe")
        var state = ChatSceneState(
            directory: [local.id: local, bot.id: bot, unrelated.id: unrelated], me: remote.id,
            sidebarPreferences: .init(sections: [.init(id: "directMessage", sort: .name)])
        )
        state.browser.query = "ava"; state.browser.people = [local, remote, remote]
        #expect(PeopleDirectoryProjection.build(state) == [local])
        state.me = nil
        #expect(PeopleDirectoryProjection.build(state) == [local, remote])
    }

    @Test func peopleUseActivityOrNameInEitherDirection() {
        let alpha = Member(id: .init("a"), kind: .human, displayName: "Alpha")
        let zebra = Member(id: .init("z"), kind: .human, displayName: "Zebra")
        let chats = [
            Conversation(
                id: .init("chat-a"),
                kind: .directMessage,
                lastActivity: Date(timeIntervalSince1970: 20),
                members: [alpha.id]
            ),
            Conversation(
                id: .init("chat-z"),
                kind: .directMessage,
                lastActivity: Date(timeIntervalSince1970: 10),
                members: [zebra.id]
            )
        ]
        func ids(_ sort: SidebarSortOrder, _ ascending: Bool) -> [Member.ID] {
            let state = ChatSceneState(
                conversations: chats, directory: [alpha.id: alpha, zebra.id: zebra],
                sidebarPreferences: .init(sections: [
                    .init(id: "directMessage", sort: sort, isAscending: ascending)
                ])
            )
            return PeopleDirectoryProjection.build(state).map(\.id)
        }
        #expect(ids(.name, true) == [alpha.id, zebra.id])
        #expect(ids(.name, false) == [zebra.id, alpha.id])
        #expect(ids(.activity, true) == [zebra.id, alpha.id])
        #expect(ids(.activity, false) == [alpha.id, zebra.id])
    }

    @Test func peopleWithoutActivityBreakTiesAToZEvenNewestFirst() {
        let alpha = Member(id: .init("a"), kind: .human, displayName: "Alpha")
        let zebra = Member(id: .init("z"), kind: .human, displayName: "Zebra")
        let state = ChatSceneState(directory: [zebra.id: zebra, alpha.id: alpha])
        #expect(PeopleDirectoryProjection.build(state).map(\.id) == [alpha.id, zebra.id])
    }

    @Test func pickerOffersLocalMatchesBeforeTheDirectoryAnswersAndSkipsTheChosen() {
        let ava = Member(id: .init("ava"), kind: .human, displayName: "Ava", email: "ava@example.test")
        let avery = Member(id: .init("avery"), kind: .human, displayName: "Avery")
        let bot = Member(id: .init("bot"), kind: .app, displayName: "Ava Bot")
        let me = Member(id: .init("me"), kind: .human, displayName: "Avi")
        let state = ChatSceneState(
            directory: [ava.id: ava, avery.id: avery, bot.id: bot, me.id: me], me: me.id
        )
        let local = PeopleDirectoryProjection.candidates(in: state, query: "av", found: [], excluding: [])
        #expect(local.map(\.id) == [ava.id, avery.id])
        let remote = Member(id: .init("remote"), kind: .human, displayName: "Zed", email: "zed@example.test")
        let both = PeopleDirectoryProjection.candidates(
            in: state, query: "av", found: [remote], excluding: [ava.id]
        )
        #expect(both.map(\.id) == [avery.id, remote.id])
    }

    @Test func pickerSuggestsOnlyTheMostRecentWithNoQuery() {
        let people = (0 ..< 20).map { Member(id: .init("p\($0)"), kind: .human, displayName: "P\($0)") }
        let chats = [Conversation(
            id: .init("chat"), kind: .directMessage,
            lastActivity: Date(timeIntervalSince1970: 5), members: [people[19].id]
        )]
        let state = ChatSceneState(
            conversations: chats,
            directory: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        )
        let suggested = PeopleDirectoryProjection.candidates(
            in: state, query: "", found: people, excluding: [], suggestionLimit: 3
        )
        #expect(suggested.map(\.id) == [people[19].id, people[0].id, people[1].id])
    }

    @Test func choosingAnotherSortStartsInItsNaturalOrder() {
        let newestFirst = SidebarSectionPreference(id: "space", sort: .activity, isAscending: false)
        let byName = SidebarSortTitles.changing(newestFirst, to: .name)
        #expect(byName.sort == .name && byName.sortsAscending)
        #expect(SidebarSortTitles.order(byName.sort, ascending: byName.sortsAscending) == "A to Z")
        let unchanged = SidebarSortTitles.changing(newestFirst, to: .activity)
        #expect(unchanged == newestFirst)
    }
}
