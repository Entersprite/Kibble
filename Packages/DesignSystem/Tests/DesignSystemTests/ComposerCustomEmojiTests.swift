import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct ComposerCustomEmojiTests {
    let emoji = CustomEmojiRef(id: "custom-1", shortcode: "party__parrot", imageToken: "opaque")

    @Test func pickedEmojiMovesThroughEditsTrimFormattingAndSavedDrafts() throws {
        var draft = ComposerDraft()
        draft.edit("  😀 ")
        draft.insertEmoji(ReactionChoice(customEmoji: emoji))
        draft.replace(location: 0, length: 0, with: "x")
        #expect(draft.customEmoji.first?.start == 6)
        let address = ComposerDraftAddress(conversation: .init("chat"), thread: nil)
        let snapshot = draft.snapshot(at: address)
        let restored = try ComposerDraft(snapshot: JSONDecoder().decode(
            ComposerSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        ))
        #expect(restored.customEmoji == draft.customEmoji)
        let message = restored.composed(formatting: true)
        #expect(message.content?.customEmoji.first?.range(in: message.text) != nil)
        var editing = restored
        editing.beginEditing(.init("message"), with: message, formatting: true)
        #expect(editing.customEmoji == message.content?.customEmoji)
        _ = editing.endEditing(formatting: true)
        #expect(editing.customEmoji == restored.customEmoji)
        let start = try #require(draft.customEmoji.first?.start)
        draft.replace(location: start + 2, length: 1, with: "x")
        #expect(draft.customEmoji.isEmpty)
    }

    @Test func refusedDraftMergePreservesBothCustomChoices() {
        var first = ComposerDraft()
        first.insertEmoji(ReactionChoice(customEmoji: emoji))
        let failed = first.composed()
        first.edit("next ")
        first.insertEmoji(ReactionChoice(customEmoji: emoji))
        let adopted = first.adopt(failed)
        #expect(adopted)
        let merged = first.composed()
        #expect(merged.content?.customEmoji.count == 2)
        #expect(merged.content?.customEmoji.allSatisfy { $0.range(in: merged.text) != nil } == true)
    }

    @Test func statusPicksAnActualCustomReferenceAndPresetsReplaceIt() throws {
        var draft = StatusDraft(current: nil)
        draft.customEmoji = emoji
        #expect(draft.canSave)
        let status = try #require(draft.status(now: Date(), calendar: .current))
        #expect(status.customEmoji == emoji)
        #expect(StatusDraft(current: status).customEmoji == emoji)
        draft.apply(StatusPreset.all[0])
        #expect(draft.customEmoji == nil)
        #expect(!draft.emoji.isEmpty)
    }
}
