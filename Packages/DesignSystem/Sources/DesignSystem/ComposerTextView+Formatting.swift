#if os(macOS)
    import AppKit
    import ChatKit

    /// What reaches the field from outside the typing: the emoji picker's
    /// text, and the Format submenu's and the format shortcuts' styles and
    /// list. Each goes through the view, never by setting the draft, so it
    /// reaches the draft by the delegate route, moves the tokens and runs
    /// after it, and is one step Cmd-Z can take back.
    extension ComposerTextView.Coordinator {
        /// A Format choice: the style on or off over the selection, or for
        /// what is typed next; for a list, `- ` before each selected line.
        func apply(_ format: ComposerFormat, in view: NSTextView) {
            if let style = format.style {
                toggle(style, in: view)
            } else {
                prefixLines(with: format.marker, in: view)
            }
        }

        /// The field's context menu, with Format first where the conversation
        /// can be formatted: every choice, the styles on at the selection
        /// checked, and the shortcuts shown that the field answers itself.
        /// There is no format button and no Format menu in the menu bar; this
        /// is where formatting lives (owner decision).
        func textView(_ view: NSTextView, menu: NSMenu, for _: NSEvent, at _: Int) -> NSMenu? {
            guard parent.formatting else { return menu }
            let item = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: ComposerFormat.menuSymbol, accessibilityDescription: nil)
            item.submenu = formatMenu(for: view)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        func formatMenu(for view: NSTextView) -> NSMenu {
            let on = ComposerFormat.choices(for: parent.draft.activeStyles(in: view.selectedRange()))
            let menu = NSMenu(title: "Format")
            for format in ComposerFormat.allCases {
                if format == .code {
                    menu.addItem(.separator())
                }
                let trampoline = ReactionMenuTrampoline { [weak self, weak view] in
                    guard let self, let view else { return }
                    view.window?.makeFirstResponder(view)
                    apply(format, in: view)
                }
                let item = NSMenuItem(
                    title: format.title, action: #selector(ReactionMenuTrampoline.choose(_:)),
                    keyEquivalent: format.keyEquivalent
                )
                item.keyEquivalentModifierMask = format.keyEquivalentModifiers
                item.target = trampoline
                // `target` is weak: the item keeps the trampoline alive itself.
                item.representedObject = trampoline
                item.state = on.contains(format) ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        func perform(_ insertion: ComposerInsertion, in view: NSTextView) {
            if let style = insertion.toggle {
                toggle(style, in: view)
            } else if let prefix = insertion.linePrefix {
                prefixLines(with: prefix, in: view)
            } else {
                if let emoji = insertion.customEmoji, let data = try? JSONEncoder().encode(emoji) {
                    let value = NSMutableAttributedString(
                        string: insertion.text,
                        attributes: view.typingAttributes
                    )
                    value.addAttribute(
                        ComposerStyle.emojiKey,
                        value: data,
                        range: NSRange(location: 0, length: value.length)
                    )
                    let range = commitComposition(in: view) ?? view.selectedRange()
                    view.insertText(value, replacementRange: range)
                } else {
                    insert(insertion.text, in: view)
                }
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

        /// The styles on at the selection, for whoever listens (`onStyles`).
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
