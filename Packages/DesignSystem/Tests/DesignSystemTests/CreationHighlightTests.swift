import ChatKit
import Testing
@testable import DesignSystem

/// The creation sheet's one highlight, which the arrows and the pointer share,
/// under the Spotlight rule: while the field holds text, Return adds the
/// highlighted match; with it empty, Return creates.
struct CreationHighlightTests {
    private let ada = Member.ID("ada")
    private let bob = Member.ID("bob")

    @Test func withTextThePickOrTheTopMatchIsDrawn() {
        #expect(CreationHighlight.shown(query: "a", highlighted: nil, top: ada) == ada)
        #expect(CreationHighlight.shown(query: "a", highlighted: bob, top: bob) == bob)
    }

    @Test func withAnEmptyFieldOnlyARowUnderThePointerIsDrawn() {
        #expect(CreationHighlight.shown(query: "", highlighted: nil, top: ada) == nil)
        #expect(CreationHighlight.shown(query: "", highlighted: bob, top: bob) == bob)
    }

    @Test func thePointerPicksTheRowItEnters() {
        #expect(CreationHighlight.hovering(bob, inside: true, query: "a", highlighted: ada) == bob)
        #expect(CreationHighlight.hovering(bob, inside: true, query: "", highlighted: nil) == bob)
    }

    /// Leaving a row clears it only with the field empty; with text, the pick
    /// stays for Return, as an arrow's does, and another row's pick is kept.
    @Test func leavingARowClearsItOnlyWithAnEmptyField() {
        #expect(CreationHighlight.hovering(bob, inside: false, query: "", highlighted: bob) == nil)
        #expect(CreationHighlight.hovering(bob, inside: false, query: "b", highlighted: bob) == bob)
        #expect(CreationHighlight.hovering(bob, inside: false, query: "", highlighted: ada) == ada)
    }
}
