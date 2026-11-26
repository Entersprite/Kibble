#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// Where formatting lives now that there is no format button and no
    /// Format menu in the menu bar: the field's own context menu, and the
    /// format keys the field answers itself.
    extension ComposerFormattingHostedTests {
        /// Right-click: where the conversation can be formatted, Format comes
        /// first, every choice in it, the styles on at the selection checked,
        /// and the format keys shown. Choosing one formats the selection.
        @Test func theContextMenuOffersFormatWithTheSelectionsStylesChecked() async throws {
            let box = Box()
            let hosted = try hosted(box, formatting: true)
            type("plain bold", in: hosted)
            hosted.view.setSelectedRange(NSRange(location: 6, length: 4))
            await choose(.bold, in: hosted, box)
            let delegate = try #require(hosted.view.delegate as? ComposerTextView.Coordinator)
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1
            ))
            let menu = try #require(delegate.textView(hosted.view, menu: NSMenu(), for: event, at: 7))
            let format = try #require(menu.items.first)
            #expect(format.title == "Format")
            let items = try #require(format.submenu).items.filter { !$0.isSeparatorItem }
            #expect(items.map(\.title) == ComposerFormat.allCases.map(\.title))
            #expect(items.filter { $0.state == .on }.map(\.title) == ["Bold"])
            #expect(items.first?.keyEquivalent == "b")
            #expect(items.first?.keyEquivalentModifierMask == [.command])

            hosted.view.setSelectedRange(NSRange(location: 0, length: 5))
            let italic = try #require(
                delegate.formatMenu(for: hosted.view).items.first { $0.title == "Italic" }
            )
            hosted.undo.beginUndoGrouping()
            (italic.target as? ReactionMenuTrampoline)?.choose(nil)
            hosted.undo.endUndoGrouping()
            #expect(box.draft.runs.contains(ComposerDraft.Run(style: .italic, location: 0, length: 5)))

            // A conversation that cannot be formatted offers no Format at all.
            let plain = try self.hosted(Box())
            let plainDelegate = try #require(plain.view.delegate as? ComposerTextView.Coordinator)
            let untouched = try #require(
                plainDelegate.textView(plain.view, menu: NSMenu(), for: event, at: 0)
            )
            #expect(untouched.items.isEmpty)
            withExtendedLifetime((hosted.window, plain.window)) {}
        }

        /// Cmd-B in the field, with nothing selected, makes what is typed next
        /// bold, as the menu's choice does.
        @Test func commandBInTheFieldFormatsWithNoMenu() throws {
            let box = Box()
            let hosted = try hosted(box, formatting: true)
            type("say ", in: hosted)
            let commandB = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: hosted.window.windowNumber, context: nil, characters: "b",
                charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11
            ))
            #expect(hosted.view.performKeyEquivalent(with: commandB))
            #expect(box.draft.typingOverride == [.bold])
            type("hi", in: hosted)
            #expect(box.draft.runs == [ComposerDraft.Run(style: .bold, location: 4, length: 2)])
            withExtendedLifetime(hosted.window) {}
        }
    }
#endif
