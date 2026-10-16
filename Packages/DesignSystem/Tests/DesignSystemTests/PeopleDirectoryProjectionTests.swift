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
}
