import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The Details section's draft: what counts as an edit, what Save sends, and
/// the limits it checks before sending.
struct DetailsDraftTests {
    private static let everything: Set<String> = [
        "details", "rename", "description", "guidelines", "emoji"
    ]

    private func details(
        _ kind: Conversation.Kind = .space,
        allowed: Set<String> = everything,
        emoji: String? = "🎨"
    ) -> ConversationDetails {
        ConversationDetails(
            conversation: Conversation(id: .init("c"), kind: kind, title: "Design Studio"),
            description: "Work in progress",
            membership: .joined,
            allowedActions: allowed,
            guidelines: "Post drafts in threads.",
            settings: kind == .space ? ConversationSettings(emoji: emoji) : nil,
            fieldLimits: ["name": 128, "description": 150, "guidelines": 5000]
        )
    }

    @Test func editingBackToTheOriginalIsClean() {
        var draft = DetailsDraft(details())
        #expect(!draft.isDirty)
        draft.name = "Design Studio Crew"
        draft.description = ""
        draft.guidelines += " No client files."
        draft.emoji = "🚀"
        #expect(draft.isDirty)
        draft.name = "Design Studio"
        draft.description = "Work in progress"
        draft.guidelines = "Post drafts in threads."
        draft.emoji = "🎨"
        #expect(!draft.isDirty)
        #expect(draft.patch() == nil)
    }

    @Test func patchContainsOnlyChangedFields() {
        var draft = DetailsDraft(details())
        draft.description = "new"
        #expect(draft.patch() == ConversationDetailsPatch(description: "new"))
    }

    @Test func clearingAFieldSendsEmpty() {
        var draft = DetailsDraft(details())
        draft.guidelines = ""
        #expect(draft.patch()?.guidelines == "")
        #expect(draft.patch()?.name == nil)
        #expect(draft.isValid)
    }

    @Test func useDefaultIconSendsEmptyEmoji() {
        var draft = DetailsDraft(details())
        draft.emoji = ""
        #expect(draft.patch() == ConversationDetailsPatch(emoji: ""))
        // A space already on its default icon has nothing to restore.
        var plain = DetailsDraft(details(emoji: nil))
        plain.emoji = ""
        #expect(!plain.isDirty)
    }

    @Test func lengthCountsUTF16() {
        #expect(DetailsDraft.length("👍🏽") == 4)
        #expect(DetailsDraft.length("abc") == 3)
    }

    @Test func aSpaceNeedsANameAndLimitsAreEnforced() {
        var draft = DetailsDraft(details())
        #expect(draft.limit("name") == 128)
        draft.name = "   "
        #expect(!draft.isValid)
        draft.name = String(repeating: "a", count: 127) + "👍"
        #expect(DetailsDraft.length(draft.name) == 129)
        #expect(!draft.isValid)
        draft.name = String(repeating: "a", count: 126) + "👍"
        #expect(draft.isValid)
        draft.description = String(repeating: "d", count: 151)
        #expect(!draft.isValid)
    }

    @Test func aGroupChatMayClearItsName() {
        var draft = DetailsDraft(details(.groupDirectMessage))
        draft.name = ""
        #expect(draft.isValid)
        #expect(draft.patch() == ConversationDetailsPatch(name: ""))
    }

    /// Without the server's permission a field is never sent, even if edited.
    @Test func onlyAllowedFieldsAreSent() {
        var draft = DetailsDraft(details(allowed: ["details", "description"]))
        draft.name = "Renamed"
        draft.description = "new"
        #expect(draft.patch() == ConversationDetailsPatch(description: "new"))
        var none = DetailsDraft(details(allowed: ["rename", "description"]))
        none.description = "new"
        #expect(none.patch() == nil)
        #expect(!none.isDirty)
    }

    /// A reload that isn't the saved answer keeps what the person typed and
    /// takes the server's new values for the rest.
    @Test func rebasingKeepsEditsAndTakesNewValues() {
        var draft = DetailsDraft(details())
        draft.description = "typed"
        var reloaded = details()
        reloaded.guidelines = "Changed elsewhere."
        let rebased = draft.rebased(onto: reloaded)
        #expect(rebased.description == "typed")
        #expect(rebased.guidelines == "Changed elsewhere.")
        #expect(rebased.patch() == ConversationDetailsPatch(description: "typed"))
        // The saved answer: the edit now matches the server, so it is clean.
        reloaded.description = "typed"
        #expect(!draft.rebased(onto: reloaded).isDirty)
    }
}
