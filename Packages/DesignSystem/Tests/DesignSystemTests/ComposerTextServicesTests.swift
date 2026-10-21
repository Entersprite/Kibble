#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The system's text services in the composer: spelling, checked while
    /// typing and remembered across fields; Writing Tools, kept off the
    /// mentions; and the formatting table the field's Format submenu and its
    /// keyboard share.
    @MainActor
    struct ComposerTextServicesTests {
        private static func defaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: "composer-spelling-\(UUID().uuidString)"))
        }

        @Test func spellingIsCheckedWhileTypingByDefault() throws {
            let view = try ComposerScrollView.make(spelling: ComposerSpelling(defaults: Self.defaults()))
                .textView
            #expect(view.isContinuousSpellCheckingEnabled)
        }

        /// The composer is built afresh for each conversation; a choice made
        /// in one field is there in the next.
        @Test func theSpellingAndGrammarChoicesCarryToTheNextField() throws {
            let defaults = try Self.defaults()
            let first = ComposerScrollView.make(spelling: ComposerSpelling(defaults: defaults)).textView
            let grammar = !first.isGrammarCheckingEnabled
            let correction = !first.isAutomaticSpellingCorrectionEnabled
            first.toggleContinuousSpellChecking(nil)
            first.toggleGrammarChecking(nil)
            first.toggleAutomaticSpellingCorrection(nil)

            let next = ComposerScrollView.make(spelling: ComposerSpelling(defaults: defaults)).textView
            #expect(!next.isContinuousSpellCheckingEnabled)
            #expect(next.isGrammarCheckingEnabled == grammar)
            #expect(next.isAutomaticSpellingCorrectionEnabled == correction)
        }

        /// Untouched, grammar and correction stay AppKit's, which follow
        /// System Settings: nothing is written until the person chooses.
        @Test func nothingIsRememberedUntilThePersonChooses() throws {
            let defaults = try Self.defaults()
            _ = ComposerScrollView.make(spelling: ComposerSpelling(defaults: defaults))
            #expect(defaults.object(forKey: ComposerSpelling.spellingKey) == nil)
            #expect(defaults.object(forKey: ComposerSpelling.grammarKey) == nil)
            #expect(defaults.object(forKey: ComposerSpelling.correctionKey) == nil)
        }

        @Test func writingToolsGivesPlainText() {
            #expect(ComposerScrollView.make().textView.allowedWritingToolsResultOptions == .plainText)
        }

        private static func draft() -> ComposerDraft {
            var draft = ComposerDraft()
            draft.edit("Ask @")
            draft.pick(.user(Member.ID("u-1")), name: "Jane Doe")
            draft.edit(draft.text + "and @")
            draft.pick(.all, name: "all")
            return draft
        }

        @Test func writingToolsIgnoresEachMention() {
            let draft = Self.draft()
            #expect(draft.text == "Ask @Jane Doe and @all ")
            let whole = NSRange(location: 0, length: (draft.text as NSString).length)
            #expect(ComposerWritingTools.ignoredRanges(of: draft.tokens, in: whole) == [
                NSRange(location: 4, length: 9), NSRange(location: 18, length: 4)
            ])
        }

        /// Only what lies in the range asked about, cut at its edges.
        @Test func writingToolsIgnoresOnlyMentionsInTheRangeAskedAbout() {
            let tokens = Self.draft().tokens
            #expect(ComposerWritingTools.ignoredRanges(of: tokens, in: NSRange(location: 14, length: 9))
                == [NSRange(location: 18, length: 4)])
            #expect(ComposerWritingTools.ignoredRanges(of: tokens, in: NSRange(location: 8, length: 3))
                == [NSRange(location: 8, length: 3)])
            #expect(ComposerWritingTools.ignoredRanges(of: tokens, in: NSRange(location: 0, length: 4))
                .isEmpty)
        }

        /// Through the delegate, as AppKit asks for them.
        @Test func theFieldAnswersWritingToolsWithTheMentions() {
            let draft = Self.draft()
            let representable = ComposerTextView(
                draft: .constant(draft), anchorX: .constant(0), listOpen: false, focusRequest: 0,
                onKey: { _ in }, onSubmit: {}
            )
            let coordinator = representable.makeCoordinator()
            // AppKit finds them by selector; a near-miss name would compile
            // and never be called.
            #expect(coordinator.responds(
                to: #selector(NSTextViewDelegate.textView(_:writingToolsIgnoredRangesInEnclosingRange:))
            ))
            #expect(coordinator.responds(to: #selector(NSTextViewDelegate.textViewWritingToolsDidEnd(_:))))
            let view = ComposerScrollView.make().textView
            let ranges = coordinator.textView(
                view, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: 23)
            )
            #expect(ranges.map(\.rangeValue) == [
                NSRange(location: 4, length: 9),
                NSRange(location: 18, length: 4)
            ])
        }

        /// A format key reaches the field only while it has the keyboard, and
        /// only where the conversation can be formatted; another field in the
        /// window keeps its own keys.
        @Test func theFieldAnswersTheFormatKeysOnlyWhileItHasTheKeyboard() throws {
            let scroll = ComposerScrollView.make()
            let field = try #require(scroll.textView as? ComposerNSTextView)
            var chosen: [ComposerFormat] = []
            field.formatShortcut = { chosen.append($0) }
            let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 100, height: 20))
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            content.addSubview(scroll)
            content.addSubview(other)
            let window = NSWindow(
                contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = content
            let commandB = try #require(Self.key("b", [.command], in: window))
            let shiftCommandX = try #require(Self.key("X", [.command, .shift], in: window))

            window.makeFirstResponder(field)
            #expect(field.performKeyEquivalent(with: commandB))
            #expect(field.performKeyEquivalent(with: shiftCommandX))
            window.makeFirstResponder(other)
            #expect(!field.performKeyEquivalent(with: commandB))
            field.formatShortcut = nil
            window.makeFirstResponder(field)
            #expect(!field.performKeyEquivalent(with: commandB))

            #expect(chosen == [.bold, .strikethrough])
            withExtendedLifetime(window) {}
        }

        private static func key(
            _ characters: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow
        ) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
            )
        }

        @Test func aKeyPressNamesItsFormatOnlyWithExactlyItsModifiers() {
            #expect(ComposerFormat.choice(key: "b", modifiers: [.command]) == .bold)
            #expect(ComposerFormat.choice(key: "I", modifiers: [.command]) == .italic)
            #expect(ComposerFormat.choice(key: "u", modifiers: [.command]) == .underline)
            #expect(ComposerFormat.choice(key: "X", modifiers: [.command, .shift]) == .strikethrough)
            // Shift-Command-U is Mark as Read, and Command-X is Cut.
            #expect(ComposerFormat.choice(key: "u", modifiers: [.command, .shift]) == nil)
            #expect(ComposerFormat.choice(key: "x", modifiers: [.command]) == nil)
            #expect(ComposerFormat.choice(key: "b", modifiers: []) == nil)
            #expect(ComposerFormat.choice(key: nil, modifiers: [.command]) == nil)
            // Caps Lock and the function key do not change the choice.
            #expect(ComposerFormat.choice(key: "b", modifiers: [.command, .capsLock, .function]) == .bold)
        }

        @Test func theFormatTableIsTheSubmenusAndTheKeys() {
            #expect(ComposerFormat.allCases.map(\.title) == [
                "Bold", "Italic", "Underline", "Strikethrough", "Code", "Code Block", "Bulleted List"
            ])
            #expect(ComposerFormat.allCases.map(\.marker) == ["**", "*", "__", "~~", "`", "```", "- "])
            #expect(ComposerFormat.keyed == [.bold, .italic, .underline, .strikethrough])
            let symbol = NSImage(systemSymbolName: ComposerFormat.menuSymbol, accessibilityDescription: nil)
            #expect(symbol != nil)
        }

        @Test func theFormatShortcutsAreTheConventionalOnes() {
            #expect(ComposerFormat.bold.shortcut == KeyboardShortcut("b"))
            #expect(ComposerFormat.italic.shortcut == KeyboardShortcut("i"))
            #expect(ComposerFormat.underline.shortcut == KeyboardShortcut("u"))
            #expect(ComposerFormat.strikethrough.shortcut == KeyboardShortcut(
                "x",
                modifiers: [.command, .shift]
            ))
            #expect(ComposerFormat.code.shortcut == nil)
            let shortcuts = ComposerFormat.allCases.compactMap(\.shortcut)
            #expect(Set(shortcuts.map { "\($0.key.character)\($0.modifiers.rawValue)" }).count == shortcuts
                .count)
        }
    }
#endif
