#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI

    /// What the field hands to the `@` list while it is open.
    enum ComposerKey: Equatable {
        case up, down, pick, dismiss
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
        let listOpen: Bool
        /// Bumped to take focus: on appearing, and when a draft is restored.
        let focusRequest: Int
        let onKey: (ComposerKey) -> Void
        let onSubmit: () -> Void

        static let maxLines = 6

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> ComposerScrollView {
            let scroll = ComposerScrollView.make()
            scroll.textView.delegate = context.coordinator
            context.coordinator.show(draft, in: scroll.textView)
            return scroll
        }

        func updateNSView(_ scroll: ComposerScrollView, context: Context) {
            context.coordinator.parent = self
            context.coordinator.show(draft, in: scroll.textView)
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
            /// Set while this class writes into the view, so the delegate
            /// callbacks it causes are not read as the person's edits.
            private var applying = false

            init(_ parent: ComposerTextView) {
                self.parent = parent
            }

            /// Puts the draft into the view when they differ: a send cleared
            /// it, a restore filled it, a pick replaced the query.
            func show(_ draft: ComposerDraft, in view: NSTextView) {
                guard view.string != draft.text else { return }
                applying = true
                view.string = draft.text
                ComposerStyle.apply(draft.tokens, to: view)
                view.setSelectedRange(NSRange(location: draft.caret, length: 0))
                applying = false
                reportAnchor(in: view)
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
                ComposerStyle.apply(parent.draft.tokens, to: view)
                parent.draft.moveCaret(to: view.selectedRange().location)
                reportAnchor(in: view)
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard !applying, let view = notification.object as? NSTextView else { return }
                parent.draft.moveCaret(to: view.selectedRange().location)
                reportAnchor(in: view)
            }

            func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
                let open = parent.listOpen
                switch selector {
                case #selector(NSResponder.moveUp(_:)) where open:
                    parent.onKey(.up)
                case #selector(NSResponder.moveDown(_:)) where open:
                    parent.onKey(.down)
                case #selector(NSResponder.insertTab(_:)) where open:
                    parent.onKey(.pick)
                case #selector(NSResponder.cancelOperation(_:)) where open:
                    parent.onKey(.dismiss)
                case #selector(NSResponder.insertNewline(_:)):
                    if open {
                        parent.onKey(.pick)
                    } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        return false
                    } else {
                        parent.onSubmit()
                    }
                case #selector(NSResponder.insertTab(_:)):
                    view.window?.selectNextKeyView(nil)
                case #selector(NSResponder.deleteBackward(_:)):
                    return deleteToken(in: view)
                default:
                    return false
                }
                return true
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

    /// A scroll view around the text view, so a seventh line scrolls rather
    /// than grows the bar.
    final class ComposerScrollView: NSScrollView {
        /// An explicit TextKit 1 stack, as `BubbleTextView` builds one: the
        /// `@` anchor reads `layoutManager`, and asking a TextKit 2 view for
        /// one would switch it over at that moment.
        private(set) var textView: NSTextView = {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
            layout.addTextContainer(container)
            return NSTextView(frame: .zero, textContainer: container)
        }()

        static func make() -> ComposerScrollView {
            let scroll = ComposerScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            let text = scroll.textView
            text.isRichText = false
            text.allowsUndo = true
            text.drawsBackground = false
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.lineFragmentPadding = 0
            text.textContainerInset = .zero
            text.font = ComposerStyle.font
            text.typingAttributes = ComposerStyle.base
            scroll.documentView = text
            return scroll
        }
    }

    /// The field's type and token style. Tokens use the accent style
    /// `MentionAttributes` gives someone else's mention in a bubble.
    enum ComposerStyle {
        static var font: NSFont {
            .preferredFont(forTextStyle: .body)
        }

        static var base: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: NSColor.labelColor]
        }

        static func apply(_ tokens: [ComposerDraft.Token], to view: NSTextView) {
            guard let storage = view.textStorage, !view.hasMarkedText() else { return }
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            let semibold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            for token in tokens where token.end <= storage.length {
                storage.addAttributes(
                    [.font: semibold, .foregroundColor: NSColor.controlAccentColor],
                    range: NSRange(location: token.location, length: token.length)
                )
            }
            storage.endEditing()
            view.typingAttributes = base
        }

        /// Measured on a private TextKit stack, never the view's own (CLAUDE.md,
        /// session 45): one line at least, `maxLines` at most.
        static func height(of text: NSAttributedString, width: CGFloat, maxLines: Int) -> CGFloat {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(
                width: max(1, width),
                height: CGFloat.greatestFiniteMagnitude
            ))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            var used = layout.usedRect(for: container)
            if !layout.extraLineFragmentRect.isEmpty {
                used = used.union(layout.extraLineFragmentRect)
            }
            let line = layout.defaultLineHeight(for: font)
            return min(max(used.height, line), line * CGFloat(maxLines)).rounded(.up)
        }
    }
#endif
