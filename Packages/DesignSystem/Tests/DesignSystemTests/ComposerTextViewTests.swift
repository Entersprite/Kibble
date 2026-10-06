#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The text view's coordinator, driven the way AppKit drives it: edits
    /// through `insertText`, keys through `doCommandBy`.
    @MainActor
    struct ComposerTextViewTests {
        @MainActor
        final class Box {
            var draft = ComposerDraft()
            var keys: [ComposerKey] = []
            var submits = 0
        }

        private func make(_ box: Box, listOpen: Bool) -> (ComposerTextView.Coordinator, NSTextView) {
            let representable = ComposerTextView(
                draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                anchorX: .constant(0),
                listOpen: listOpen,
                focusRequest: 0,
                onKey: { box.keys.append($0) },
                onSubmit: { box.submits += 1 }
            )
            let coordinator = representable.makeCoordinator()
            let scroll = ComposerScrollView.make()
            scroll.textView.delegate = coordinator
            return (coordinator, scroll.textView)
        }

        @Test func typingReachesTheDraft() {
            let box = Box()
            let (_, view) = make(box, listOpen: false)
            view.insertText("@ja", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(box.draft.text == "@ja")
            #expect(box.draft.activeQuery?.text == "ja")
        }

        @Test func returnWithTheListOpenPicksAndDoesNotSubmit() {
            let box = Box()
            let (coordinator, view) = make(box, listOpen: true)
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(box.keys == [.pick])
            #expect(box.submits == 0)
        }

        @Test func returnWithTheListClosedSubmits() {
            let box = Box()
            let (coordinator, view) = make(box, listOpen: false)
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(box.submits == 1)
        }

        @Test func arrowsTabAndEscapeGoToTheOpenList() {
            let box = Box()
            let (coordinator, view) = make(box, listOpen: true)
            _ = coordinator.textView(view, doCommandBy: #selector(NSResponder.moveDown(_:)))
            _ = coordinator.textView(view, doCommandBy: #selector(NSResponder.moveUp(_:)))
            _ = coordinator.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:)))
            _ = coordinator.textView(view, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            #expect(box.keys == [.down, .up, .pick, .dismiss])
        }

        @Test func arrowsWithTheListClosedMoveTheCaretAsUsual() {
            let box = Box()
            let (coordinator, view) = make(box, listOpen: false)
            #expect(!coordinator.textView(view, doCommandBy: #selector(NSResponder.moveUp(_:))))
        }

        @Test func backspaceAtATokensEndRemovesTheWholeToken() {
            let box = Box()
            let (coordinator, view) = make(box, listOpen: false)
            view.insertText("@ja", replacementRange: NSRange(location: NSNotFound, length: 0))
            box.draft.pick(.user(Member.ID("u-1")), name: "Jane")
            coordinator.show(box.draft, in: view)
            view.setSelectedRange(NSRange(location: 5, length: 0))
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
            #expect(view.string == " ")
            #expect(box.draft.text == " ")
            #expect(box.draft.tokens.isEmpty)
        }

        @Test func aDraftChangedElsewhereIsShown() {
            let box = Box()
            let (coordinator, view) = make(box, listOpen: false)
            box.draft.replace(location: 0, length: 0, with: "restored")
            coordinator.show(box.draft, in: view)
            #expect(view.string == "restored")
        }
    }
#endif
