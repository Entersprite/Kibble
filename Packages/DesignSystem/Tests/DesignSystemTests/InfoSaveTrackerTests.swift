import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// When a `details` change is a section's saved answer (start over) and when
/// it is just a reload (keep the typing), driven the way the Details form
/// drives it: Save, the model's `isSubmitting`, `details`, then the turn ending.
struct InfoSaveTrackerTests {
    private func details(description: String = "Work in progress") -> ConversationDetails {
        ConversationDetails(
            conversation: Conversation(id: .init("c"), kind: .space, title: "Design Studio"),
            description: description,
            membership: .joined,
            allowedActions: ["details", "description"],
            settings: ConversationSettings(),
            fieldLimits: ["description": 150]
        )
    }

    /// A Save the model dropped never starts submitting; a later reload must
    /// not be mistaken for its answer.
    @Test func aSaveThatNeverStartsKeepsRebasing() {
        var saves = InfoSaveTracker()
        var draft = DetailsDraft(details())
        draft.description = "typed"
        saves.saveRequested()
        #expect(!saves.isAnswer(submitting: false, error: nil))
        saves.saveMustHaveStarted()
        #expect(saves.phase == .idle)

        var reloaded = details()
        reloaded.guidelines = "Changed elsewhere."
        draft = draft.updated(to: reloaded, isAnswer: saves.isAnswer(submitting: false, error: nil))
        #expect(draft.description == "typed")
        #expect(draft.isDirty)
    }

    @Test func aConfirmedSaveEndsClean() {
        var saves = InfoSaveTracker()
        var draft = DetailsDraft(details())
        draft.description = "typed "
        saves.saveRequested()
        saves.submittingChanged(true)
        saves.saveMustHaveStarted()
        #expect(saves.phase == .submitting)

        // The answer, in the same turn submitting ends; the server tidied the text.
        let answer = details(description: "typed")
        draft = draft.updated(to: answer, isAnswer: saves.isAnswer(submitting: false, error: nil))
        saves.submittingChanged(false)
        saves.landed()
        #expect(!draft.isDirty)
        #expect(saves.phase == .idle)

        // Either order within that turn: submitting ends first, then the answer.
        var other = InfoSaveTracker()
        var second = DetailsDraft(details())
        second.description = "typed "
        other.saveRequested()
        other.submittingChanged(true)
        other.submittingChanged(false)
        #expect(other.phase == .landing)
        second = second.updated(to: answer, isAnswer: other.isAnswer(submitting: false, error: nil))
        other.landed()
        #expect(!second.isDirty)
    }

    /// The same refusal twice changes no `panelError`; the draft must stay
    /// dirty, and the next reload must keep the typing.
    @Test func aRepeatedIdenticalErrorKeepsTheTyping() {
        var saves = InfoSaveTracker()
        var draft = DetailsDraft(details())
        draft.description = "typed"
        for _ in 0 ..< 2 {
            saves.saveRequested()
            saves.submittingChanged(true)
            saves.submittingChanged(false)
            saves.landed()
            #expect(saves.phase == .idle)
        }
        draft = draft.updated(to: details(), isAnswer: saves.isAnswer(submitting: false, error: nil))
        #expect(draft.description == "typed")
        #expect(draft.isDirty)
    }

    /// A refused Save with a reload landing in the same turn: the reload is
    /// not the answer, and the typing stays for another try.
    @Test func aFailedSaveWithASameTurnReloadKeepsTheTyping() {
        var saves = InfoSaveTracker()
        var draft = DetailsDraft(details())
        draft.description = "typed"
        saves.saveRequested()
        saves.submittingChanged(true)
        saves.submittingChanged(false)
        #expect(saves.phase == .landing)
        let error = "The change failed."
        #expect(!saves.isAnswer(submitting: false, error: error))
        draft = draft.updated(to: details(), isAnswer: saves.isAnswer(submitting: false, error: error))
        saves.landed()
        #expect(draft.description == "typed")
        #expect(draft.isDirty)
    }

    /// A reload landing while the write is still in flight is not its answer.
    @Test func aReloadDuringTheWriteIsNotTheAnswer() {
        var saves = InfoSaveTracker()
        saves.saveRequested()
        saves.submittingChanged(true)
        #expect(!saves.isAnswer(submitting: true, error: nil))
        #expect(saves.isAnswer(submitting: false, error: nil))
    }

    /// Another write's submission (Leave…, say) doesn't arm the tracker.
    @Test func anotherWriteIsNotTheAnswer() {
        var saves = InfoSaveTracker()
        saves.submittingChanged(true)
        saves.submittingChanged(false)
        #expect(saves.phase == .idle)
        #expect(!saves.isAnswer(submitting: false, error: nil))
    }
}
