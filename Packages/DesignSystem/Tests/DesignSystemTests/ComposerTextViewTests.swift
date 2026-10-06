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

        /// In a window, so the text view has an undo manager. Grouping by hand:
        /// a test has no event loop to close the groups.
        struct Windowed {
            let coordinator: ComposerTextView.Coordinator
            let view: NSTextView
            let window: NSWindow
            let undo: UndoManager
        }

        private func windowed(_ box: Box) -> Windowed {
            let representable = ComposerTextView(
                draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                anchorX: .constant(0),
                listOpen: false,
                focusRequest: 0,
                onKey: { _ in },
                onSubmit: {}
            )
            let coordinator = representable.makeCoordinator()
            let scroll = ComposerScrollView.make()
            scroll.textView.delegate = coordinator
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = scroll
            let undo = scroll.textView.undoManager ?? UndoManager()
            undo.groupsByEvent = false
            return Windowed(coordinator: coordinator, view: scroll.textView, window: window, undo: undo)
        }

        private func type(_ text: String, into view: NSTextView, undo: UndoManager) {
            undo.beginUndoGrouping()
            view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            undo.endUndoGrouping()
        }

        /// Review finding 1: a send sets the text outright, and undo then
        /// replayed ranges from the old text - an `NSRangeException`.
        @Test func aSendLeavesNothingToUndo() {
            let box = Box()
            let harness = windowed(box)
            type("hello", into: harness.view, undo: harness.undo)
            #expect(harness.undo.canUndo)
            box.draft.clear()
            harness.coordinator.show(box.draft, in: harness.view)
            #expect(!harness.undo.canUndo)
            withExtendedLifetime(harness.window) {}
        }

        /// Undo edits the storage without the delegate's edit callbacks, so
        /// the draft must follow the view rather than the other way round.
        @Test func undoingTypingKeepsTheDraftInStep() {
            let box = Box()
            let harness = windowed(box)
            type("ab", into: harness.view, undo: harness.undo)
            harness.undo.undo()
            #expect(harness.view.string.isEmpty)
            #expect(box.draft.text.isEmpty)
            withExtendedLifetime(harness.window) {}
        }

        /// Review finding 2: with a zero `maxSize` the text view never grew
        /// past its frame, so a seventh line could not be scrolled to.
        @Test func theFieldCanGrowPastItsFrameSoItScrolls() {
            let scroll = ComposerScrollView.make()
            #expect(scroll.textView.maxSize.height > 10000)
        }

        /// Review finding 3: an editable text view accepts file drags, which
        /// took them from the conversation's drop target (session 50).
        @Test func filesDroppedOnTheFieldAreLeftToTheConversation() {
            let types = ComposerScrollView.make().textView.acceptableDragTypes
            #expect(!types.contains(.fileURL))
            #expect(!types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")))
            #expect(!types.contains(.URL))
        }

        /// Review finding 9: the old `TextField` carried "Message …" as its
        /// label; the text view must say it to VoiceOver itself.
        @Test func theFieldCarriesItsLabelForVoiceOver() {
            let view = ComposerScrollView.make().textView
            ComposerTextView.describe(view, placeholder: "Message Jane")
            #expect(view.accessibilityLabel() == "Message Jane")
            #expect(view.accessibilityPlaceholderValue() == "Message Jane")
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
