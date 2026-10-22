import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// While the saved copy is up and the newest page is on its way, the header
/// says so in place of its count.
@MainActor
struct TranscriptLoadingStateTests {
    private let chat = Conversation.ID("space/s-1")
    private let row = Message.ID("m-1")

    private func scene(loading: Bool, unconfirmed: Set<Message.ID>) -> ChatSceneState {
        var conversation = Conversation(id: chat, kind: .space, title: "Quick Sync")
        conversation.memberCount = 12
        return ChatSceneState(
            conversations: [conversation], selected: chat,
            isLoadingMessages: loading, unconfirmedMessages: unconfirmed
        )
    }

    private func subtitle(_ scene: ChatSceneState) -> String {
        ChatWindow(state: scene, actions: ChatSceneActions(select: { _ in }, send: { _ in })).subtitle
    }

    @Test func theSavedCopyLoadingSaysUpdating() {
        #expect(subtitle(scene(loading: true, unconfirmed: [row])) == "Updating…")
    }

    /// A chat whose rows are all confirmed keeps its count while it refreshes.
    @Test func aConfirmedChatKeepsItsCountWhileLoading() {
        #expect(subtitle(scene(loading: true, unconfirmed: [])) == "12 members")
    }

    /// A failed page leaves the saved copy up, without claiming to update it.
    @Test func aSavedCopyNoLongerLoadingKeepsItsCount() {
        #expect(subtitle(scene(loading: false, unconfirmed: [row])) == "12 members")
    }
}
