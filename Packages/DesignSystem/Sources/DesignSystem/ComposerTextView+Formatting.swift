#if os(macOS)
    import AppKit

    /// What reaches the field from outside the keyboard: the emoji picker's
    /// text, a list's `- `, and the format button's and Format menu's styles.
    /// Each goes through the view, never by setting the draft, so it reaches
    /// the draft by the delegate route, moves the tokens and runs after it,
    /// and is one step Cmd-Z can take back.
    extension ComposerTextView.Coordinator {
        func perform(_ insertion: ComposerInsertion, in view: NSTextView) {
            if let style = insertion.toggle {
                toggle(style, in: view)
            } else if let prefix = insertion.linePrefix {
                prefixLines(with: prefix, in: view)
            } else {
                insert(insertion.text, in: view)
            }
        }

        /// Text over the selection. Mid-composition (an input method's marked
        /// text), the composition is kept as typed and the text goes after
        /// it, rather than splitting it.
        func insert(_ text: String, in view: NSTextView) {
            let range = commitComposition(in: view) ?? view.selectedRange()
            view.insertText(text, replacementRange: range)
        }

        /// `prefix` before each selected line, as one undoable step: a list
        /// is typed `- ` lines, which Send reads as list items.
        func prefixLines(with prefix: String, in view: NSTextView) {
            let range = commitComposition(in: view) ?? view.selectedRange()
            let source = view.string as NSString
            let lines = source.lineRange(for: range)
            var starts = [lines.location]
            for index in lines.location ..< NSMaxRange(lines) where source.character(at: index) == 10 {
                if index + 1 < NSMaxRange(lines) {
                    starts.append(index + 1)
                }
            }
            view.undoManager?.beginUndoGrouping()
            for start in starts.reversed() {
                view.insertText(prefix, replacementRange: NSRange(location: start, length: 0))
            }
            view.undoManager?.endUndoGrouping()
        }

        /// Cmd-B and its kind, as Notes has them (`ComposerDraft.toggle`).
        ///
        /// Over a selection, the change is written into the text storage
        /// through `shouldChangeText`, so AppKit records it as one step Cmd-Z
        /// takes back, formatting and all; the draft then reads it back
        /// (`textDidChange`). With nothing selected only the typing style
        /// changes, which, as in Notes, is nothing to undo; the typing before
        /// and after it become separate steps.
        func toggle(_ style: ComposerDraft.Style, in view: NSTextView) {
            _ = commitComposition(in: view)
            var next = parent.draft
            view.breakUndoCoalescing()
            guard let range = next.toggle(style, in: view.selectedRange()) else {
                parent.draft = next
                ComposerStyle.setTyping(next.typingStyles, in: view)
                reportStyles(in: view)
                return
            }
            guard let storage = view.textStorage,
                  view.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            ComposerStyle.mark(next.runs, in: range, of: storage)
            storage.endEditing()
            if let title = ComposerFormat.allCases.first(where: { $0.style == style })?.title {
                view.undoManager?.setActionName(title)
            }
            view.didChangeText()
        }

        /// The styles on at the selection, for the Format menu's checkmarks.
        func reportStyles(in view: NSTextView) {
            parent.onStyles?(parent.draft.activeStyles(in: view.selectedRange()))
        }

        /// The same, once the view update that changed the draft's text is
        /// over: a report writes the composer's state, which an update must
        /// not.
        func reportStylesLater(in view: NSTextView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                reportStyles(in: view)
            }
        }

        /// Ends an input method's composition as typed, and says where it
        /// ended; `nil` when there was none.
        private func commitComposition(in view: NSTextView) -> NSRange? {
            guard view.hasMarkedText() else { return nil }
            let end = NSRange(location: NSMaxRange(view.markedRange()), length: 0)
            view.unmarkText()
            view.inputContext?.discardMarkedText()
            return end
        }
    }
#endif
