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
            _ box: Box, listOpen: Bool = false, upEdits: Bool = false, escCancels: Bool = false
        ) -> (ComposerTextView.Coordinator, NSTextView) {
            let representable = ComposerTextView(
                draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                anchorX: .constant(0),
                listOpen: listOpen,
                focusRequest: 0,
                onKey: { box.keys.append($0) },
                onSubmit: {},
                upEdits: upEdits,
                escCancels: escCancels
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
            let (coordinator, view) = make(box, escCancels: true)
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            #expect(box.keys == [.cancelEdit])
        }
    }
#endif
