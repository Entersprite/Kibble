import Testing
@testable import DesignSystem

/// The composer's draft, and the one decision about it worth testing.
///
/// A value type rather than a test against `Composer`'s own `@State`: this
/// package's tests drive decisions, not views - `ConnectionBanner`'s
/// `offersReconnect(for:)` and `SidebarSections` are the same shape. A
/// `@State String` inside a `View` is not reachable from a test, and pretending
/// otherwise would mean asserting on a copy of the logic rather than on the
/// logic.
struct ComposerDraftTests {
    /// The ordinary case, on every redraw where nothing failed.
    @Test func noRestoreValueLeavesTheDraftAlone() {
        var draft = ComposerDraft()
        draft.edit("half-typed")

        #expect(draft.adopt(nil) == false)
        #expect(draft.text == "half-typed")
    }

    @Test func aRestoreValueIsAdoptedAndReported() {
        var draft = ComposerDraft()

        #expect(draft.adopt("came back") == true)
        #expect(draft.text == "came back")
    }

    /// **The one that matters.** The host clears its own copy after adopting,
    /// but a redraw can arrive with the same value still in hand - and
    /// re-adopting it would overwrite whatever the user has typed since.
    @Test func theSameValueIsNotAdoptedTwice() {
        var draft = ComposerDraft()
        #expect(draft.adopt("came back") == true)
        draft.edit("and then I kept typing")

        #expect(draft.adopt("came back") == false)
        #expect(draft.text == "and then I kept typing")
    }

    /// Going back to `nil` forgets what was adopted, so the identical text
    /// failing a second time is offered again rather than silently dropped.
    @Test func aNilResetsSoTheSameTextCanFailAgain() {
        var draft = ComposerDraft()
        #expect(draft.adopt("same words") == true)
        #expect(draft.adopt(nil) == false)

        #expect(draft.adopt("same words") == true)
        #expect(draft.text == "same words")
    }

    @Test func anEmptyRestoreValueIsNotAdopted() {
        var draft = ComposerDraft()
        draft.edit("mine")

        #expect(draft.adopt("") == false)
        #expect(draft.text == "mine")
    }
}
