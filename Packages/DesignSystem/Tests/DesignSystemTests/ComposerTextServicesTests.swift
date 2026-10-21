#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The system's text services in the composer: spelling, checked while
    /// typing and remembered across fields; Writing Tools, kept off the
    /// mentions; and the formatting table the format button and the Format
    /// menu share.
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

        /// The Format menu follows the field's keyboard focus, which the text
        /// view reports itself.
        @Test func theFieldReportsWhenItHasTheKeyboard() throws {
            let scroll = ComposerScrollView.make()
            let field = try #require(scroll.textView as? ComposerNSTextView)
            var reports: [Bool] = []
            field.focusChanged = { reports.append($0) }
            let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 100, height: 20))
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            content.addSubview(scroll)
            content.addSubview(other)
            let window = NSWindow(
                contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = content

            window.makeFirstResponder(field)
            window.makeFirstResponder(other)

            #expect(reports == [true, false])
            withExtendedLifetime(window) {}
        }

        @Test func theFormatTableIsTheButtonsAndTheMenus() {
            #expect(ComposerFormat.allCases.map(\.title) == [
                "Bold", "Italic", "Underline", "Strikethrough", "Code", "Code Block", "Bulleted List"
            ])
            #expect(ComposerFormat.allCases.map(\.marker) == ["**", "*", "__", "~~", "`", "```", "- "])
            #expect(ComposerFormat.menuBarItems == [.bold, .italic, .underline, .strikethrough, .code])
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

        /// The value the Format menu reads is one per composer, not one per
        /// keystroke.
        @Test func formattingFromOneComposerIsOneValue() {
            let id = UUID()
            #expect(ComposerFormatting(id: id) { _ in } == ComposerFormatting(id: id) { _ in })
            #expect(ComposerFormatting(id: id) { _ in } != ComposerFormatting(id: UUID()) { _ in })
        }
    }
#endif
