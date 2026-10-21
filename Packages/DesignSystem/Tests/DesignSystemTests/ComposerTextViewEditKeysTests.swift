#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// Up and Esc in edit mode, driven through `doCommandBy` as AppKit drives
    /// them (edit spec §5). The decisions are `ComposerEditKeys`'; this checks
    /// the text view routes them and leaves the keys alone otherwise.
    @MainActor
    struct ComposerTextViewEditKeysTests {
        @MainActor
        final class Box {
            var draft = ComposerDraft()
            var keys: [ComposerKey] = []
        }

        private func make(
            _ box: Box, listOpen: Bool = false, upEdits: Bool = false,
            escape: ComposerEditKeys.Escape = .nothing
        ) -> (ComposerTextView.Coordinator, NSTextView) {
            let representable = ComposerTextView(
                draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                anchorX: .constant(0),
                listOpen: listOpen,
                focusRequest: 0,
                onKey: { box.keys.append($0) },
                onSubmit: {},
                upEdits: upEdits,
                escape: escape
            )
            let coordinator = representable.makeCoordinator()
            let scroll = ComposerScrollView.make()
            scroll.textView.delegate = coordinator
            return (coordinator, scroll.textView)
        }

        @Test func upEditsWhenTheComposerSaysSo() {
            let box = Box()
            let (coordinator, view) = make(box, upEdits: true)
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.moveUp(_:))))
            #expect(box.keys == [.editNewest])
        }

        @Test func otherwiseUpIsTheTextViewsOwn() {
            let box = Box()
            let (coordinator, view) = make(box)
            #expect(!coordinator.textView(view, doCommandBy: #selector(NSResponder.moveUp(_:))))
            #expect(box.keys.isEmpty)
        }

        /// The open list still gets Up first.
        @Test func anOpenListTakesUpBeforeAnEdit() {
            let box = Box()
            let (coordinator, view) = make(box, listOpen: true, upEdits: true)
            _ = coordinator.textView(view, doCommandBy: #selector(NSResponder.moveUp(_:)))
            #expect(box.keys == [.up])
        }

        @Test func escCancelsWhenTheComposerSaysSo() {
            let box = Box()
            let (coordinator, view) = make(box, escape: .cancelEdit)
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            #expect(box.keys == [.cancelEdit])
        }

        @Test func escDropsAQuoteWhenTheComposerSaysSo() {
            let box = Box()
            let (coordinator, view) = make(box, escape: .cancelQuote)
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            #expect(box.keys == [.cancelQuote])
        }

        /// With nothing to undo, Esc is taken and does nothing: returning
        /// `false` let the text view run `complete:`, which opened a
        /// word-completion list.
        @Test func escWithNothingToUndoIsTakenAndSendsNothing() {
            let box = Box()
            let (coordinator, view) = make(box)
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            #expect(box.keys.isEmpty)
        }

        /// Shift-Tab leaves the field backwards, as Tab leaves it forwards.
        @Test func shiftTabMovesTheKeyboardToThePreviousControl() throws {
            let box = Box()
            let (coordinator, view) = make(box)
            let previous = NSTextField(frame: NSRect(x: 0, y: 60, width: 100, height: 20))
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            let scroll = try #require(view.enclosingScrollView)
            scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            content.addSubview(scroll)
            content.addSubview(previous)
            previous.nextKeyView = view
            view.nextKeyView = previous
            let window = NSWindow(
                contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = content
            window.makeFirstResponder(view)

            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertBacktab(_:))))

            #expect(box.keys.isEmpty)
            #expect(window.firstResponder !== view)
            #expect((window.firstResponder as? NSText)?.delegate === previous || window
                .firstResponder === previous)
            withExtendedLifetime(window) {}
        }
    }
#endif
