#if os(macOS)
    import AppKit
    import SwiftUI

    /// The microphone button: the field takes focus, then the app starts
    /// system dictation, as Edit › Start Dictation does. `startDictation:` is
    /// that menu item's action and is not in Apple's documentation;
    /// `NSApplication` answers it (checked on macOS 26, session 59). Sent up
    /// the responder chain from the field, the way the menu sends it. Whether
    /// dictated text lands in this field is `[Verify]`, and no test can reach
    /// it, which is why it is this one function.
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

        /// `spelling` is where the person's Spelling and Grammar choices are
        /// kept (`ComposerSpelling`); a test passes its own.
        static func make(spelling: ComposerSpelling = ComposerSpelling()) -> ComposerScrollView {
            let scroll = ComposerScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            let text = scroll.textView
            // Plain text to the person: a paste or a drop arrives as text,
            // never with another app's fonts. The field's own formatting is
            // drawn from the draft (`ComposerStyle`), which plain text allows.
            text.isRichText = false
            text.allowsUndo = true
            spelling.apply(to: text)
            (text as? ComposerNSTextView)?.spelling = spelling
            // Writing Tools rewrites the words and keeps the field plain: its
            // rich results would carry styles the draft cannot send, and what
            // it rewrites comes in unstyled (`ComposerDraft.edit`). Mentions
            // are kept out of its reach by the delegate's ignored ranges
            // (`ComposerTextView.Coordinator`).
            text.allowedWritingToolsResultOptions = .plainText
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

    /// The person's Spelling and Grammar choices, from the field's Edit and
    /// context menus, kept for the next field. The composer is built afresh
    /// for every conversation, and an `NSTextView` starts from AppKit's
    /// defaults each time, so a choice made in one conversation was gone in
    /// the next. Device-wide, like the system's own text settings.
    ///
    /// Spelling is checked while typing until the person turns it off.
    /// Grammar and automatic correction keep AppKit's defaults, which follow
    /// System Settings, until the person chooses in the field.
    struct ComposerSpelling {
        static let spellingKey = "ComposerChecksSpellingWhileTyping"
        static let grammarKey = "ComposerChecksGrammarWithSpelling"
        static let correctionKey = "ComposerCorrectsSpellingAutomatically"

        var defaults: UserDefaults = .standard

        @MainActor
        func apply(to view: NSTextView) {
            view.isContinuousSpellCheckingEnabled = defaults.object(forKey: Self.spellingKey) as? Bool ?? true
            if let grammar = defaults.object(forKey: Self.grammarKey) as? Bool {
                view.isGrammarCheckingEnabled = grammar
            }
            if let correction = defaults.object(forKey: Self.correctionKey) as? Bool {
                view.isAutomaticSpellingCorrectionEnabled = correction
            }
        }
    }

    /// The composer's text view: what it accepts from a drag and a paste,
    /// the format keys it answers, and the Spelling and Grammar choices it
    /// remembers.
    final class ComposerNSTextView: NSTextView {
        /// Set while the composer can stage files (`ComposerPaste`).
        var paste: ComposerPaste?
        /// Set where the conversation can be formatted: Cmd-B, Cmd-I, Cmd-U
        /// and Shift-Cmd-X format while this field has the keyboard. No menu
        /// bar item claims those keys, so they reach the window, which offers
        /// them to its views before anything else.
        var formatShortcut: ((ComposerFormat) -> Void)?
        var spelling = ComposerSpelling()

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let formatShortcut, window?.firstResponder === self, !hasMarkedText(),
               let format = ComposerFormat.choice(
                   key: event.charactersIgnoringModifiers, modifiers: event.modifierFlags
               ) {
                formatShortcut(format)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        /// Accepts dragged text only. An editable text view takes file and
        /// URL drags by default, and AppKit gives a drag to the deepest view
        /// that registered for it, so a file dropped on the field missed the
        /// conversation's drop target and was not staged.
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            [.string]
        }

        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            guard let paste else { return super.readablePasteboardTypes }
            return ComposerPaste.readableTypes(
                text: super.readablePasteboardTypes,
                images: paste.image != nil
            )
        }

        override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            if let paste, let staged = paste.read(pboard, type: type) {
                return staged
            }
            return super.readSelection(from: pboard, type: type)
        }

        override func toggleContinuousSpellChecking(_ sender: Any?) {
            super.toggleContinuousSpellChecking(sender)
            spelling.defaults.set(isContinuousSpellCheckingEnabled, forKey: ComposerSpelling.spellingKey)
        }

        override func toggleGrammarChecking(_ sender: Any?) {
            super.toggleGrammarChecking(sender)
            spelling.defaults.set(isGrammarCheckingEnabled, forKey: ComposerSpelling.grammarKey)
        }

        override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
            super.toggleAutomaticSpellingCorrection(sender)
            spelling.defaults.set(
                isAutomaticSpellingCorrectionEnabled,
                forKey: ComposerSpelling.correctionKey
            )
        }
    }
#endif
