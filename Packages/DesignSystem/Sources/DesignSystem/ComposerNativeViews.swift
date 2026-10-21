#if os(macOS)
    import AppKit
    import SwiftUI

    /// Messages' waveform: the field takes focus, then the app starts system
    /// dictation, as Edit › Start Dictation does. `startDictation:` is that
    /// menu item's action and is not in Apple's documentation; `NSApplication`
    /// answers it (checked on macOS 26, session 59). Sent up the responder
    /// chain from the field, the way the menu sends it. Whether dictated text
    /// lands in this field is `[Verify]`, and no test can reach it, which is
    /// why it is this one function.
    @MainActor
    enum ComposerDictation {
        static func start(in view: NSTextView) {
            view.window?.makeFirstResponder(view)
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: view)
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
            return ComposerNSTextView(frame: .zero, textContainer: container)
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
            // Without these the view never grows past its frame, and a seventh
            // line cannot be scrolled to (review finding 2).
            text.minSize = .zero
            text.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
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
    /// `MessageTextAttributes` gives someone else's mention in a bubble.
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

    /// Accepts dragged text only. An editable text view takes file and URL
    /// drags by default, and AppKit gives a drag to the deepest view that
    /// registered for it, so a file dropped on the field missed the
    /// conversation's drop target and was not staged (review finding 3).
    final class ComposerNSTextView: NSTextView {
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            [.string]
        }
    }
#endif
