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
        /// Whether this conversation can be formatted: the field's context
        /// menu then has a Format submenu, and Cmd-B, Cmd-I, Cmd-U and
        /// Shift-Cmd-X format while it has the keyboard (`ComposerFormat`).
        var formatting = false
        /// Told the styles on at the caret or over the whole selection
        /// (`ComposerDraft.activeStyles`), after every change.
        var onStyles: ((Set<ComposerDraft.Style>) -> Void)?

        static let maxLines = 6

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> ComposerScrollView {
            let scroll = ComposerScrollView.make()
            scroll.textView.delegate = context.coordinator
            Self.describe(scroll.textView, placeholder: placeholder)
            connect(scroll.textView, to: context.coordinator)
            Self.cover(scroll.textView, context.environment.coveredByPanel)
            context.coordinator.show(draft, in: scroll.textView)
            return scroll
        }

        /// The current paste and shortcut callbacks, on every update: the
        /// paste closes over this composer's latest state.
        private func connect(_ view: NSTextView, to coordinator: Coordinator) {
            guard let view = view as? ComposerNSTextView else { return }
            view.paste = paste
            view.formatShortcut = formatting
                ? { [weak coordinator, weak view] format in
                    guard let coordinator, let view else { return }
                    coordinator.apply(format, in: view)
                }
                : nil
        }

        /// No text cursor over the field while a panel covers it (`HostedTextView`).
        static func cover(_ view: NSTextView, _ covered: Bool) {
            (view as? HostedTextView)?.showsTextCursor = !covered
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
            connect(scroll.textView, to: coordinator)
            Self.cover(scroll.textView, context.environment.coveredByPanel)
            coordinator.show(draft, in: scroll.textView)
            // Both after this update, because both write the draft's binding,
            // which an update must not; and the field takes focus first, since
            // the picker's popover or the microphone's click had it.
            if let insertion = coordinator.takeInsertion(insertion) {
                DispatchQueue.main.async {
                    scroll.window?.makeFirstResponder(scroll.textView)
                    coordinator.perform(insertion, in: scroll.textView)
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
            var applying = false

            init(_ parent: ComposerTextView) {
                self.parent = parent
                // What the view already held is not new (review finding 2).
                insertion = parent.insertion?.id
                dictationRequest = parent.dictationRequest
            }

            /// Puts the draft into the view when they differ: a send cleared
            /// it, a restore filled it, a pick replaced the query. A restore
            /// over the same words can differ in formatting alone, and Cmd-B
            /// with nothing selected changes only what typing takes.
            func show(_ draft: ComposerDraft, in view: NSTextView) {
                guard let storage = view.textStorage else { return }
                if view.string != draft.text {
                    applying = true
                    view.string = draft.text
                    // Setting the text outright bypasses undo, so the undo stack
                    // still holds ranges into the old text; undoing one raised an
                    // `NSRangeException`. A send, a restore or a pick starts
                    // the field's undo history afresh.
                    view.undoManager?.removeAllActions(withTarget: storage)
                    view.setSelectedRange(NSRange(location: draft.caret, length: 0))
                    ComposerStyle.apply(draft, to: view)
                    applying = false
                    reportAnchor(in: view)
                    reportStylesLater(in: view)
                } else if !view.hasMarkedText(), !view.isWritingToolsActive,
                          ComposerStyle.runs(in: storage) != draft.runs
                          || ComposerStyle.customEmoji(in: storage) != draft.customEmoji {
                    applying = true
                    ComposerStyle.apply(draft, to: view)
                    applying = false
                    reportStylesLater(in: view)
                } else {
                    let selection = view.selectedRange()
                    ComposerStyle.setTyping(
                        draft.insertionStyles(location: selection.location, length: selection.length),
                        in: view
                    )
                }
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

            /// What Writing Tools rewrites comes in unstyled: its results are
            /// plain text, and guessing which words kept which style could
            /// put bold on the wrong ones.
            func textView(
                _ view: NSTextView,
                shouldChangeTextIn range: NSRange,
                replacementString string: String?
            ) -> Bool {
                guard !applying, let string else { return true }
                parent.draft.replace(
                    location: range.location, length: range.length, with: string,
                    styles: view.isWritingToolsActive ? [] : nil
                )
                return true
            }

            func textDidChange(_ notification: Notification) {
                guard !applying, let view = notification.object as? NSTextView,
                      let storage = view.textStorage else { return }
                if view.isWritingToolsActive {
                    if view.string != parent.draft.text {
                        parent.draft.edit(view.string)
                    }
                } else {
                    // An undo or redo, which puts back formatting with its
                    // text, a format change (`toggle`), a composition, or
                    // anything the routing above missed: the view holds what
                    // the person sees, and the draft follows it.
                    let runs = ComposerStyle.runs(in: storage)
                    if view.string != parent.draft.text || runs != parent.draft.runs
                        || ComposerStyle.customEmoji(in: storage) != parent.draft.customEmoji {
                        parent.draft.follow(
                            view.string,
                            runs: runs,
                            customEmoji: ComposerStyle.customEmoji(in: storage)
                        )
                    }
                }
                parent.onActivity?(!view.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                parent.draft.moveCaret(to: view.selectedRange().location)
                // Restyling resets the storage's attributes, which Writing
                // Tools is animating while it rewrites; the styles go back on
                // when it ends.
                if !view.isWritingToolsActive {
                    ComposerStyle.apply(parent.draft, to: view)
                }
                reportAnchor(in: view)
                reportStyles(in: view)
            }

            /// The mentions, which Writing Tools leaves as written: a rewrite
            /// that reworded "@Jane Doe" would turn the mention into plain text
            /// (`ComposerDraft.replace`), and nobody would be notified. Code,
            /// too, which a rewrite would break.
            func textView(
                _: NSTextView,
                writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange
            ) -> [NSValue] {
                ComposerWritingTools.ignoredRanges(
                    of: parent.draft.tokens, code: parent.draft.runs, in: enclosingRange
                )
                .map { NSValue(range: $0) }
            }

            func textViewWritingToolsDidEnd(_ view: NSTextView) {
                ComposerStyle.apply(parent.draft, to: view)
            }

            func textDidEndEditing(_ notification: Notification) {
                parent.onActivity?(false)
            }

            /// The caret's styles become the typing styles, as in any Mac
            /// text view: the field is plain text to AppKit, which therefore
            /// never picks them up itself (measured on macOS 27).
            func textViewDidChangeSelection(_ notification: Notification) {
                guard !applying, let view = notification.object as? NSTextView else { return }
                let selection = view.selectedRange()
                parent.draft.moveCaret(to: selection.location)
                ComposerStyle.setTyping(
                    parent.draft.insertionStyles(location: selection.location, length: selection.length),
                    in: view
                )
                reportAnchor(in: view)
                reportStyles(in: view)
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
        /// Each mention token's span within `enclosing`, then each code and
        /// code block run's, in the text view's own offsets (UTF-16, as the
        /// draft keeps them), cut to `enclosing` where one straddles its edge.
        static func ignoredRanges(
            of tokens: [ComposerDraft.Token],
            code runs: [ComposerDraft.Run] = [],
            in enclosing: NSRange
        ) -> [NSRange] {
            let spans = tokens.map { NSRange(location: $0.location, length: $0.length) }
                + runs.filter { $0.style == .code || $0.style == .codeBlock }
                .map { NSRange(location: $0.location, length: $0.length) }
            return spans.compactMap { span in
                guard let overlap = span.intersection(enclosing), overlap.length > 0 else { return nil }
                return overlap
            }
        }
    }

#endif
