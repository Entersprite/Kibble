#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// Formatting in the field as a person meets it: hosted in a window, a
    /// style arrives through the field (an insertion through `updateNSView`,
    /// acted on a turn of the main queue later, or the field's Format submenu
    /// and keys), and text arrives as the keyboard types it. Bold is bold in
    /// the text storage, and no markup reaches the text.
    @MainActor
    struct ComposerFormattingHostedTests {
        @MainActor
        final class Box {
            var draft = ComposerDraft()
            var styles: Set<ComposerDraft.Style> = []
            /// Whether the field formats, kept across every rebuild of it.
            var formatting = false
        }

        struct Hosted {
            let host: NSHostingView<ComposerTextView>
            let window: NSWindow
            let view: NSTextView
            let undo: UndoManager
        }

        private func field(_ box: Box, insertion: ComposerInsertion? = nil) -> ComposerTextView {
            ComposerTextView(
                draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                anchorX: .constant(0),
                listOpen: false,
                focusRequest: 0,
                onKey: { _ in },
                onSubmit: {},
                insertion: insertion,
                formatting: box.formatting,
                onStyles: { box.styles = $0 }
            )
        }

        func hosted(_ box: Box, formatting: Bool = false) throws -> Hosted {
            box.formatting = formatting
            let host = NSHostingView(rootView: field(box))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let view = try #require(Self.textView(in: host))
            window.makeFirstResponder(view)
            // Grouped by hand: a test has no event loop to close the groups.
            let undo = try #require(view.undoManager)
            undo.groupsByEvent = false
            return Hosted(host: host, window: window, view: view, undo: undo)
        }

        private static func textView(in view: NSView) -> NSTextView? {
            if let text = view as? ComposerNSTextView {
                return text
            }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }

        /// What the keyboard does: one undoable step per string.
        func type(_ text: String, in hosted: Hosted) {
            hosted.undo.beginUndoGrouping()
            hosted.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            hosted.undo.endUndoGrouping()
        }

        /// A style chosen from outside the typing, as one step, and waits,
        /// bounded, until the field has acted on it.
        func choose(_ style: ComposerDraft.Style, in hosted: Hosted, _ box: Box) async {
            let before = box.draft
            hosted.undo.beginUndoGrouping()
            hosted.host.rootView = field(box, insertion: ComposerInsertion(toggle: style))
            hosted.host.layoutSubtreeIfNeeded()
            await until { box.draft != before }
            hosted.undo.endUndoGrouping()
        }

        private func until(_ done: () -> Bool) async {
            for _ in 0 ..< 400 where !done() {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        private static func traits(at offset: Int, in view: NSTextView) -> NSFontDescriptor.SymbolicTraits {
            (view.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)?
                .fontDescriptor.symbolicTraits ?? []
        }

        @Test func commandBWithNothingSelectedMakesTheTypedTextBoldWithNoMarkup() async throws {
            let box = Box()
            let hosted = try hosted(box)
            type("say ", in: hosted)
            await choose(.bold, in: hosted, box)
            #expect(box.draft.typingOverride == [.bold])
            type("h", in: hosted)
            type("i", in: hosted)
            #expect(hosted.view.string == "say hi")
            #expect(box.draft.text == "say hi")
            #expect(box.draft.runs == [ComposerDraft.Run(style: .bold, location: 4, length: 2)])
            #expect(Self.traits(at: 4, in: hosted.view).contains(.bold))
            #expect(!Self.traits(at: 2, in: hosted.view).contains(.bold))
            #expect(box.draft.composed(formatting: true) == ComposedMessage(
                text: "say hi",
                content: MessageContent(formatting: [MessageFormat(style: "bold", start: 4, length: 2)])
            ))
            withExtendedLifetime(hosted.window) {}
        }

        @Test func commandBOverASelectionIsOneStepToUndoAndRedo() async throws {
            let box = Box()
            let hosted = try hosted(box)
            type("hello world", in: hosted)
            hosted.view.setSelectedRange(NSRange(location: 6, length: 5))
            await choose(.bold, in: hosted, box)
            let bold = [ComposerDraft.Run(style: .bold, location: 6, length: 5)]
            #expect(box.draft.runs == bold)
            #expect(Self.traits(at: 6, in: hosted.view).contains(.bold))
            #expect(hosted.view.selectedRange() == NSRange(location: 6, length: 5))
            #expect(hosted.undo.undoActionName == "Bold")

            hosted.undo.undo()
            #expect(box.draft.runs.isEmpty)
            #expect(box.draft.text == "hello world")
            #expect(!Self.traits(at: 6, in: hosted.view).contains(.bold))

            hosted.undo.redo()
            #expect(box.draft.runs == bold)
            #expect(Self.traits(at: 6, in: hosted.view).contains(.bold))

            // Chosen again over the same words, it comes off.
            hosted.view.setSelectedRange(NSRange(location: 6, length: 5))
            await choose(.bold, in: hosted, box)
            #expect(box.draft.runs.isEmpty)
            withExtendedLifetime(hosted.window) {}
        }

        /// AppKit's undo puts deleted text back with its attributes, and the
        /// draft reads the formatting back from them.
        @Test func undoingADeletionBringsTheTextBackStyled() async throws {
            let box = Box()
            let hosted = try hosted(box)
            type("keep bold", in: hosted)
            hosted.view.setSelectedRange(NSRange(location: 5, length: 4))
            await choose(.italic, in: hosted, box)
            hosted.view.setSelectedRange(NSRange(location: 4, length: 5))
            hosted.undo.beginUndoGrouping()
            hosted.view.delete(nil)
            hosted.undo.endUndoGrouping()
            #expect(box.draft.text == "keep")
            #expect(box.draft.runs.isEmpty)

            hosted.undo.undo()
            #expect(box.draft.text == "keep bold")
            #expect(box.draft.runs == [ComposerDraft.Run(style: .italic, location: 5, length: 4)])
            #expect(Self.traits(at: 5, in: hosted.view).contains(.italic))
            withExtendedLifetime(hosted.window) {}
        }

        /// An input method's composition takes the chosen style, keeps its
        /// marked text until it is committed, and commits styled.
        @Test func aCompositionTakesTheChosenStyle() async throws {
            let box = Box()
            let hosted = try hosted(box)
            type("a", in: hosted)
            await choose(.underline, in: hosted, box)
            hosted.undo.beginUndoGrouping()
            hosted.view.setMarkedText(
                "にほん",
                selectedRange: NSRange(location: 3, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            #expect(hosted.view.hasMarkedText())
            #expect(hosted.view.textStorage?
                .attribute(ComposerStyle.styleKey, at: 1, effectiveRange: nil) != nil)
            hosted.view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
            hosted.undo.endUndoGrouping()
            #expect(!hosted.view.hasMarkedText())
            #expect(box.draft.text == "a日本")
            #expect(box.draft.runs == [ComposerDraft.Run(style: .underline, location: 1, length: 2)])
            withExtendedLifetime(hosted.window) {}
        }

        /// A style chosen mid-composition commits the composition as typed
        /// first, as an emoji from the picker does, and applies to what is
        /// typed after it.
        @Test func aStyleChosenMidCompositionCommitsItFirst() async throws {
            let box = Box()
            let hosted = try hosted(box)
            hosted.undo.beginUndoGrouping()
            hosted.view.setMarkedText(
                "にほん",
                selectedRange: NSRange(location: 3, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            hosted.undo.endUndoGrouping()
            await choose(.italic, in: hosted, box)
            #expect(!hosted.view.hasMarkedText())
            type("x", in: hosted)
            #expect(box.draft.text == "にほんx")
            #expect(box.draft.runs == [ComposerDraft.Run(style: .italic, location: 3, length: 1)])
            withExtendedLifetime(hosted.window) {}
        }

        /// A list is still a typed `- ` before each selected line.
        @Test func aListStillTypesItsPrefix() async throws {
            let box = Box()
            let hosted = try hosted(box)
            type("one\ntwo", in: hosted)
            hosted.view.setSelectedRange(NSRange(location: 0, length: 7))
            hosted.host.rootView = field(box, insertion: ComposerInsertion(linePrefix: "- "))
            hosted.host.layoutSubtreeIfNeeded()
            await until { box.draft.text != "one\ntwo" }
            #expect(box.draft.text == "- one\n- two")
            withExtendedLifetime(hosted.window) {}
        }

        /// A restore over the same words in other styles redraws them; the
        /// text, and so the undo history, stays.
        @Test func aDraftDifferingOnlyInFormattingIsRedrawn() throws {
            let box = Box()
            let hosted = try hosted(box)
            type("same words", in: hosted)
            box.draft.toggle(.strikethrough, in: NSRange(location: 0, length: 4))
            hosted.host.rootView = field(box)
            hosted.host.layoutSubtreeIfNeeded()
            #expect(hosted.view.textStorage?
                .attribute(.strikethroughStyle, at: 1, effectiveRange: nil) != nil)
            #expect(hosted.view.textStorage?
                .attribute(.strikethroughStyle, at: 5, effectiveRange: nil) == nil)
            #expect(hosted.undo.canUndo)
            withExtendedLifetime(hosted.window) {}
        }

        /// A send sets the text outright, and a format change's undo holds
        /// ranges into the old text as typing's does: neither may survive.
        @Test func aSendLeavesNoFormatChangeToUndo() async throws {
            let box = Box()
            let hosted = try hosted(box)
            type("sent", in: hosted)
            hosted.view.setSelectedRange(NSRange(location: 0, length: 4))
            await choose(.bold, in: hosted, box)
            #expect(hosted.undo.canUndo)
            box.draft.clear()
            hosted.host.rootView = field(box)
            hosted.host.layoutSubtreeIfNeeded()
            #expect(hosted.view.string.isEmpty)
            #expect(!hosted.undo.canUndo)
            // And what is typed next is plain.
            type("next", in: hosted)
            #expect(box.draft.runs.isEmpty)
            withExtendedLifetime(hosted.window) {}
        }

        /// Pasted text is plain text, and takes the styles typing there
        /// would, as AppKit gives a plain-text paste and as Notes' Paste and
        /// Match Style does.
        @Test func pastedTextTakesTheStylesTypingThereWould() async throws {
            let box = Box()
            let hosted = try hosted(box)
            type("bold", in: hosted)
            hosted.view.setSelectedRange(NSRange(location: 0, length: 4))
            await choose(.bold, in: hosted, box)
            hosted.view.setSelectedRange(NSRange(location: 4, length: 0))
            let board = NSPasteboard(name: NSPasteboard.Name("kibble-composer-test-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            board.setString("er", forType: .string)
            hosted.undo.beginUndoGrouping()
            #expect(hosted.view.readSelection(from: board))
            hosted.undo.endUndoGrouping()
            #expect(box.draft.text == "bolder")
            #expect(box.draft.runs == [ComposerDraft.Run(style: .bold, location: 0, length: 6)])
            withExtendedLifetime(hosted.window) {}
        }

        /// The styles on at the selection follow the caret and the selection,
        /// and a style chosen for typing, as Notes' Format menu does.
        @Test func theStylesOnAtTheSelectionAreReported() async throws {
            let box = Box()
            let hosted = try hosted(box)
            type("plain bold", in: hosted)
            hosted.view.setSelectedRange(NSRange(location: 6, length: 4))
            await choose(.bold, in: hosted, box)
            #expect(box.styles == [.bold])
            hosted.view.setSelectedRange(NSRange(location: 2, length: 0))
            #expect(box.styles.isEmpty)
            hosted.view.setSelectedRange(NSRange(location: 4, length: 6))
            #expect(box.styles.isEmpty)
            hosted.view.setSelectedRange(NSRange(location: 8, length: 0))
            #expect(box.styles == [.bold])
            await choose(.bold, in: hosted, box)
            #expect(box.styles.isEmpty)
            #expect(ComposerFormat.choices(for: [.bold, .codeBlock]) == [.bold, .codeBlock])
            withExtendedLifetime(hosted.window) {}
        }

        /// Writing Tools leaves code alone as well as mentions.
        @Test func writingToolsLeavesCodeAlone() {
            var draft = ComposerDraft()
            draft.replace(location: 0, length: 0, with: "run make now")
            draft.toggle(.code, in: NSRange(location: 4, length: 4))
            draft.toggle(.bold, in: NSRange(location: 0, length: 3))
            #expect(ComposerWritingTools.ignoredRanges(
                of: draft.tokens, code: draft.runs, in: NSRange(location: 0, length: 12)
            ) == [NSRange(location: 4, length: 4)])
        }
    }
#endif
