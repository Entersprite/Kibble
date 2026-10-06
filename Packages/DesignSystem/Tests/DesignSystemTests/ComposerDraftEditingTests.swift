import ChatKit
import Testing
@testable import DesignSystem

/// The draft's edit mode (edit spec §5): the message replaces the field, and
/// whatever was there comes back when the edit ends, however it ends.
struct ComposerDraftEditingTests {
    private static let id = Message.ID("m-1")

    @Test func beginningLoadsTheMessageWithItsTokens() {
        var draft = ComposerDraft()
        let mention = Mention(target: .all, start: 0, length: 4)
        draft.beginEditing(Self.id, with: ComposedMessage(text: "@all hi", mentions: [mention]))
        #expect(draft.text == "@all hi")
        #expect(draft.tokens.count == 1)
        #expect(draft.caret == 7)
        #expect(draft.editing?.messageID == Self.id)
    }

    @Test func endingHandsBackTheEditAndRestoresWhatWasTyped() throws {
        var draft = ComposerDraft()
        draft.edit("half-typed")
        draft.beginEditing(Self.id, with: ComposedMessage(text: "old"))
        draft.edit("new")
        let result = draft.endEditing()
        let ended = try #require(result)
        #expect(ended.messageID == Self.id)
        #expect(ended.message == ComposedMessage(text: "new"))
        #expect(draft.text == "half-typed")
        #expect(draft.editing == nil)
    }

    /// A set-aside draft comes back with its tokens, untrimmed.
    @Test func theSetAsideDraftKeepsItsTokens() throws {
        var draft = ComposerDraft()
        draft.edit("  @")
        draft.pick(.all, name: "all")
        draft.beginEditing(Self.id, with: ComposedMessage(text: "old"))
        let result = draft.endEditing()
        try #require(result != nil)
        #expect(draft.text == "  @all ")
        #expect(draft.tokens.map(\.location) == [2])
    }

    /// Guard: beginning while already editing keeps the *first* set-aside
    /// draft, not the previous edit's text.
    @Test func switchingEditsKeepsTheOriginalDraft() {
        var draft = ComposerDraft()
        draft.edit("half-typed")
        draft.beginEditing(Self.id, with: ComposedMessage(text: "first"))
        draft.beginEditing(Message.ID("m-2"), with: ComposedMessage(text: "second"))
        _ = draft.endEditing()
        #expect(draft.text == "half-typed")
    }

    @Test func endingWhenNotEditingDoesNothing() {
        var draft = ComposerDraft()
        draft.edit("typed")
        let result = draft.endEditing()
        #expect(result == nil)
        #expect(draft.text == "typed")
    }

    /// Review Focus 2.
    @Test func aRestoreWhileEditingGoesToTheSetAsideDraft() {
        var draft = ComposerDraft()
        draft.beginEditing(Self.id, with: ComposedMessage(text: "editing"))
        #expect(draft.adopt(ComposedMessage(text: "failed send")) == true)
        #expect(draft.text == "editing")
        _ = draft.endEditing()
        #expect(draft.text == "failed send")
    }

    @Test func aRestoreWhileEditingKeepsWhatWasSetAsideToo() {
        var draft = ComposerDraft()
        draft.edit("half-typed")
        draft.beginEditing(Self.id, with: ComposedMessage(text: "editing"))
        _ = draft.adopt(ComposedMessage(text: "failed send"))
        _ = draft.endEditing()
        #expect(draft.text == "failed send\nhalf-typed")
    }
}
