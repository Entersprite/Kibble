#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI

    /// What the field hands to the composer: the `@` list's keys while it is
    /// open, and Up and Esc when they edit, cancel or drop a quote.
    enum ComposerKey: Equatable {
        case up, down, pick, dismiss, editNewest, cancelEdit, cancelQuote
    }

    /// The composer's text on macOS: an `NSTextView`, because a SwiftUI
    /// `TextField` neither reports its caret nor lets a token delete as one
    /// unit (mention composer spec §3.4). Every edit goes through
    /// `ComposerDraft`, which decides what happens to tokens; the view only
    /// routes, styles and forwards keys.
    struct ComposerTextView: NSViewRepresentable {
        @Binding var draft: ComposerDraft
        /// The `@`'s x position in this view, for aligning the list.
        @Binding var anchorX: CGFloat
        /// "Message …", for VoiceOver: the visible placeholder is a SwiftUI
        /// overlay the text view knows nothing about.
        var placeholder = ""
        let listOpen: Bool
        /// Bumped to take focus: on appearing, and when a draft is restored.
        let focusRequest: Int
        let onKey: (ComposerKey) -> Void
        let onSubmit: () -> Void
        /// Up edits the newest message only when the composer says so
        /// (`ComposerEditKeys`); otherwise it is the text view's own (edit
        /// spec §5).
        var upEdits = false
        /// What Esc undoes (`ComposerEditKeys.escape`).
        var escape = ComposerEditKeys.Escape.nothing
        /// Text to put in over the selection, once per new value.
        var insertion: ComposerInsertion?
        /// Bumped to start system dictation in the field (the microphone).
        var dictationRequest = 0
        var onActivity: ((Bool) -> Void)?
        /// Pasted files and pictures, while the composer can stage them.
        var paste: ComposerPaste?
        /// Told when the field gains or loses the keyboard.
        var onFocusChange: ((Bool) -> Void)?

        static let maxLines = 6

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> ComposerScrollView {
            let scroll = ComposerScrollView.make()
            scroll.textView.delegate = context.coordinator
            Self.describe(scroll.textView, placeholder: placeholder)
            connect(scroll.textView)
            context.coordinator.show(draft, in: scroll.textView)
            return scroll
        }

        /// The current paste and focus callbacks, on every update: both
        /// close over this composer's latest state.
        private func connect(_ view: NSTextView) {
            guard let view = view as? ComposerNSTextView else { return }
            view.paste = paste
            view.focusChanged = onFocusChange
        }

        /// The label and placeholder VoiceOver reads, which the `TextField`
        /// this replaced carried itself (review finding 9).
        static func describe(_ view: NSTextView, placeholder: String) {
            view.setAccessibilityLabel(placeholder)
            view.setAccessibilityPlaceholderValue(placeholder)
        }

        func updateNSView(_ scroll: ComposerScrollView, context: Context) {
            let coordinator = context.coordinator
            coordinator.parent = self
            Self.describe(scroll.textView, placeholder: placeholder)
            connect(scroll.textView)
            coordinator.show(draft, in: scroll.textView)
            // Both after this update, because both write the draft's binding,
            // which an update must not; and the field takes focus first, since
            // the picker's popover or the microphone's click had it.
            if let insertion = coordinator.takeInsertion(insertion) {
                DispatchQueue.main.async {
                    scroll.window?.makeFirstResponder(scroll.textView)
                    coordinator.insert(insertion.text, surround: insertion.surround, in: scroll.textView)
                }
            }
            if coordinator.takeDictationRequest(dictationRequest) {
                DispatchQueue.main.async { ComposerDictation.start(in: scroll.textView) }
            }
            guard context.coordinator.focusRequest != focusRequest else { return }
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { scroll.window?.makeFirstResponder(scroll.textView) }
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ComposerScrollView,
            context _: Context
        ) -> CGSize? {
            let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
            return CGSize(
                width: width,
                height: ComposerStyle.height(
                    of: nsView.textView.attributedString(),
                    width: width,
                    maxLines: Self.maxLines
                )
            )
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: ComposerTextView
            var focusRequest = -1
            /// The last insertion and dictation request acted on.
            private var insertion: UUID?
            private var dictationRequest: Int
            /// Set while this class writes into the view, so the delegate
            /// callbacks it causes are not read as the person's edits.
            private var applying = false

            init(_ parent: ComposerTextView) {
                self.parent = parent
                // What the view already held is not new (review finding 2).
                insertion = parent.insertion?.id
                dictationRequest = parent.dictationRequest
            }

            /// Puts the draft into the view when they differ: a send cleared
            /// it, a restore filled it, a pick replaced the query.
            func show(_ draft: ComposerDraft, in view: NSTextView) {
                guard view.string != draft.text else { return }
                applying = true
                view.string = draft.text
                // Setting the text outright bypasses undo, so the undo stack
                // still holds ranges into the old text; undoing one raised an
                // `NSRangeException` (review finding 1). A send, a restore or a
                // pick starts the field's undo history afresh.
                if let storage = view.textStorage {
                    view.undoManager?.removeAllActions(withTarget: storage)
                }
                ComposerStyle.apply(draft.tokens, to: view)
                view.setSelectedRange(NSRange(location: draft.caret, length: 0))
                applying = false
                reportAnchor(in: view)
            }

            /// The insertion to act on, once. `updateNSView` runs again for
            /// every change an insertion causes, so without this the same
            /// emoji went in over and over (review finding 3).
            func takeInsertion(_ new: ComposerInsertion?) -> ComposerInsertion? {
                guard let new, new.id != insertion else { return nil }
                insertion = new.id
                return new
            }

            /// Whether to start dictation: once per request.
            func takeDictationRequest(_ request: Int) -> Bool {
                guard request != dictationRequest else { return false }
                dictationRequest = request
                return true
            }

            /// Text from outside the keyboard (the emoji picker), over the
            /// selection. Through the view, never by setting the draft: the
            /// edit reaches the draft by the delegate route above, so tokens
            /// after it move, and it is one step Cmd-Z can take back.
            ///
            /// Mid-composition (an input method's marked text), the
            /// composition is kept as typed and the text goes after it, rather
            /// than splitting it (review finding 5).
            func insert(_ text: String, surround: String? = nil, in view: NSTextView) {
                var range = view.selectedRange()
                if view.hasMarkedText() {
                    range = NSRange(location: NSMaxRange(view.markedRange()), length: 0)
                    view.unmarkText()
                    view.inputContext?.discardMarkedText()
                }
                if let marker = surround {
                    view.undoManager?.beginUndoGrouping()
                    if marker == "- " {
                        let source = view.string as NSString
                        let lines = source.lineRange(for: range)
                        var starts = [lines.location]
                        for index in lines.location ..< NSMaxRange(lines)
                            where source.character(at: index) == 10 {
                            if index + 1 < NSMaxRange(lines) {
                                starts.append(index + 1)
                            }
                        }
                        for start in starts.reversed() {
                            view.insertText(marker, replacementRange: NSRange(location: start, length: 0))
                        }
                    } else {
                        view.insertText(
                            marker,
                            replacementRange: NSRange(location: NSMaxRange(range), length: 0)
                        )
                        view.insertText(
                            marker,
                            replacementRange: NSRange(location: range.location, length: 0)
                        )
                        view.setSelectedRange(NSRange(
                            location: range.location + marker.utf16.count,
                            length: range.length
                        ))
                    }
                    view.undoManager?.endUndoGrouping()
                } else {
                    view.insertText(text, replacementRange: range)
                }
            }

            func textView(
                _: NSTextView,
                shouldChangeTextIn range: NSRange,
                replacementString string: String?
            ) -> Bool {
                guard !applying, let string else { return true }
                parent.draft.replace(location: range.location, length: range.length, with: string)
                return true
            }

            func textDidChange(_ notification: Notification) {
                guard !applying, let view = notification.object as? NSTextView else { return }
                // Marked text, an undo, or anything the routing above missed.
                if view.string != parent.draft.text {
                    parent.draft.edit(view.string)
                }
                parent.onActivity?(!view.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // Restyling resets the storage's attributes, which Writing
                // Tools is animating while it rewrites; the styles go back on
                // when it ends.
                if !view.isWritingToolsActive {
                    ComposerStyle.apply(parent.draft.tokens, to: view)
                }
                parent.draft.moveCaret(to: view.selectedRange().location)
                reportAnchor(in: view)
            }

            /// The mentions, which Writing Tools leaves as written: a rewrite
            /// that reworded "@Jane Doe" would turn the mention into plain text
            /// (`ComposerDraft.replace`), and nobody would be notified.
            func textView(
                _: NSTextView,
                writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange
            ) -> [NSValue] {
                ComposerWritingTools.ignoredRanges(of: parent.draft.tokens, in: enclosingRange)
                    .map { NSValue(range: $0) }
            }

            func textViewWritingToolsDidEnd(_ view: NSTextView) {
                ComposerStyle.apply(parent.draft.tokens, to: view)
            }

            func textDidEndEditing(_ notification: Notification) {
                parent.onActivity?(false)
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard !applying, let view = notification.object as? NSTextView else { return }
                parent.draft.moveCaret(to: view.selectedRange().location)
                reportAnchor(in: view)
            }

            func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
                if let key = listKey(selector) ?? editKey(selector) {
                    parent.onKey(key)
                    return true
                }
                switch selector {
                case #selector(NSResponder.insertNewline(_:)):
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        return false
                    }
                    parent.onSubmit()
                case #selector(NSResponder.insertTab(_:)):
                    view.window?.selectNextKeyView(nil)
                case #selector(NSResponder.insertBacktab(_:)):
                    view.window?.selectPreviousKeyView(nil)
                case #selector(NSResponder.deleteBackward(_:)):
                    return deleteToken(in: view)
                case #selector(NSResponder.cancelOperation(_:)):
                    // Nothing left to undo. The text view's own Esc is
                    // `complete:`, a word-completion list nobody asked for.
                    return true
                default:
                    return false
                }
                return true
            }

            /// The open `@` list takes the keys that move and pick in it.
            private func listKey(_ selector: Selector) -> ComposerKey? {
                guard parent.listOpen else { return nil }
                switch selector {
                case #selector(NSResponder.moveUp(_:)): return .up
                case #selector(NSResponder.moveDown(_:)): return .down
                case #selector(NSResponder.insertTab(_:)),
                     #selector(NSResponder.insertNewline(_:)): return .pick
                case #selector(NSResponder.cancelOperation(_:)): return .dismiss
                default: return nil
                }
            }

            /// Up when it edits, and Esc when it cancels an edit or drops a
            /// quote, as the composer says (`ComposerEditKeys`).
            private func editKey(_ selector: Selector) -> ComposerKey? {
                switch selector {
                case #selector(NSResponder.moveUp(_:)) where parent.upEdits: .editNewest
                case #selector(NSResponder.cancelOperation(_:))
                    where parent.escape == .cancelEdit: .cancelEdit
                case #selector(NSResponder.cancelOperation(_:))
                    where parent.escape == .cancelQuote: .cancelQuote
                default: nil
                }
            }

            /// Backspace at a token's end removes the whole token, through
            /// the ordinary edit path so undo and the draft both see it.
            private func deleteToken(in view: NSTextView) -> Bool {
                let selection = view.selectedRange()
                guard selection.length == 0,
                      let token = parent.draft.token(endingAt: selection.location) else {
                    return false
                }
                let range = NSRange(location: token.location, length: token.length)
                if view.shouldChangeText(in: range, replacementString: "") {
                    view.replaceCharacters(in: range, with: "")
                    view.didChangeText()
                }
                return true
            }

            private func reportAnchor(in view: NSTextView) {
                guard let query = parent.draft.activeQuery, let layout = view.layoutManager,
                      let container = view.textContainer else { return }
                let glyphs = layout.glyphRange(
                    forCharacterRange: NSRange(location: query.location, length: 1),
                    actualCharacterRange: nil
                )
                let offset = layout.boundingRect(forGlyphRange: glyphs, in: container).minX
                    + view.textContainerOrigin.x
                guard offset != parent.anchorX else { return }
                parent.anchorX = offset
            }
        }
    }

    /// What Writing Tools must leave alone in the field, as a decision a
    /// test can reach.
    enum ComposerWritingTools {
        /// Each mention token's span within `enclosing`, in the text view's
        /// own offsets (UTF-16, as the draft keeps them), cut to `enclosing`
        /// where a token straddles its edge.
        static func ignoredRanges(of tokens: [ComposerDraft.Token], in enclosing: NSRange) -> [NSRange] {
            tokens.compactMap { token in
                let span = NSRange(location: token.location, length: token.length)
                guard let overlap = span.intersection(enclosing), overlap.length > 0 else { return nil }
                return overlap
            }
        }
    }

#endif
