import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The composer's keys in edit mode (edit spec §5), as pure decisions.
struct ComposerEditKeysTests {
    private static let mine = Message(
        id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
        threadID: MessageThread.ID("t-1"),
        sender: Member.ID("u-me"), text: "hi", createdAt: Date(timeIntervalSince1970: 0)
    )

    private func editing() -> ComposerDraft {
        var draft = ComposerDraft()
        draft.beginEditing(Self.mine.id, with: ComposedMessage(text: "hi"))
        return draft
    }

    /// Review Focus 3: staged files never go with an edit.
    @Test func whileEditingReturnSavesAndNeverSends() {
        #expect(ComposerEditKeys.submitAction(draft: editing(), canSend: true) == .save)
    }

    @Test func anEmptyEditSavesNothing() {
        var draft = editing()
        draft.edit("   ")
        #expect(ComposerEditKeys.submitAction(draft: draft, canSend: true) == .nothing)
    }

    @Test func notEditingReturnSendsAsBefore() {
        var draft = ComposerDraft()
        draft.edit("hello")
        #expect(ComposerEditKeys.submitAction(draft: draft, canSend: true) == .send)
        #expect(ComposerEditKeys.submitAction(draft: draft, canSend: false) == .nothing)
    }

    /// Review Focus 4.
    @Test func upEditsOnlyFromAnEmptyIdleComposer() {
        let empty = ComposerDraft()
        #expect(ComposerEditKeys.upEdits(draft: empty, stagedCount: 0, listOpen: false, newest: Self.mine))
        var typed = ComposerDraft()
        typed.edit("x")
        #expect(!ComposerEditKeys.upEdits(draft: typed, stagedCount: 0, listOpen: false, newest: Self.mine))
        #expect(!ComposerEditKeys.upEdits(draft: empty, stagedCount: 1, listOpen: false, newest: Self.mine))
        #expect(!ComposerEditKeys.upEdits(draft: empty, stagedCount: 0, listOpen: true, newest: Self.mine))
        #expect(!ComposerEditKeys.upEdits(draft: empty, stagedCount: 0, listOpen: false, newest: nil))
        #expect(!ComposerEditKeys.upEdits(
            draft: editing(),
            stagedCount: 0,
            listOpen: false,
            newest: Self.mine
        ))
    }

    /// Review Focus 5.
    @Test func escClosesTheListBeforeItCancelsTheEdit() {
        #expect(!ComposerEditKeys.escCancels(draft: editing(), listOpen: true))
        #expect(ComposerEditKeys.escCancels(draft: editing(), listOpen: false))
        #expect(!ComposerEditKeys.escCancels(draft: ComposerDraft(), listOpen: false))
    }
}
