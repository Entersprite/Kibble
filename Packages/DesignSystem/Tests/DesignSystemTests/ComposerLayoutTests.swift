#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The composer's geometry, measured hosted (`CLAUDE.md`: measure with
    /// `NSHostingView.fittingSize`, which runs headless). The conversation's
    /// composer has a file button and the thread's has none, and the two came
    /// out different heights.
    @MainActor
    struct ComposerLayoutTests {
        /// In a window, after one turn of the run loop: a restored draft is
        /// adopted in an `onChange`, after the first layout has been measured.
        private func height(_ composer: Composer, width: CGFloat = 420) -> CGFloat {
            let host = NSHostingView(rootView: composer.frame(width: width))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            return withExtendedLifetime(window) { host.fittingSize.height }
        }

        private var files: ComposerAttachmentActions {
            ComposerAttachmentActions(choose: {}, stage: { _ in }, remove: { _ in })
        }

        @Test func theConversationAndThreadComposersAreTheSameHeight() {
            let conversation = height(Composer(
                placeholder: "Maya", attachmentActions: files, emoji: ReactionActions(toggle: { _, _, _ in }),
                send: { _ in }
            ))
            let thread = height(Composer(placeholder: "the thread", send: { _ in }))
            #expect(conversation == thread)
        }

        /// The send arrow appeared with the first character and was taller
        /// than a line, so the field grew as you typed. A restored draft is
        /// text in the field from the first frame.
        @Test func typingALineKeepsTheHeight() {
            let empty = height(Composer(placeholder: "the thread", send: { _ in }))
            let typed = height(Composer(
                placeholder: "the thread",
                restoring: ComposedMessage(text: "On my way"),
                send: { _ in }
            ))
            #expect(typed == empty)
        }

        /// The positive control for the test above: a restored draft does
        /// reach the field in this harness.
        @Test func sixRestoredLinesAreTaller() {
            let empty = height(Composer(placeholder: "the thread", send: { _ in }))
            let six = height(Composer(
                placeholder: "the thread",
                restoring: ComposedMessage(text: "1\n2\n3\n4\n5\n6"),
                send: { _ in }
            ))
            #expect(six > empty)
        }

        /// Six lines in a capsule ran into its ends, which curve through half
        /// its height. A point 2pt in from the left, 30pt down, is on a
        /// straight side when the corners are half of one line (15.5pt), and
        /// outside a capsule's 60pt curve.
        @Test func aTallFieldHasStraightSides() {
            let tall = CGRect(x: 0, y: 0, width: 300, height: 120)
            let path = ComposerLayout.fieldShape.path(in: tall)
            #expect(path.contains(CGPoint(x: 2, y: 30)))
            #expect(path.contains(CGPoint(x: 298, y: 90)))
        }

        /// The waveform shows on an empty field, as Messages' does, and text
        /// hides it. An edit never shows it, even one emptied.
        @Test func dictationIsOfferedOnAnEmptyFieldOnly() {
            var draft = ComposerDraft()
            #expect(ComposerLayout.offersDictation(draft))
            draft.edit("On my way")
            #expect(!ComposerLayout.offersDictation(draft))
            var editing = ComposerDraft()
            editing.beginEditing(Message.ID("m-1"), with: ComposedMessage(text: "Typo"))
            editing.edit("")
            #expect(!ComposerLayout.offersDictation(editing))
        }

        /// `CLAUDE.md`: an SF Symbol name is an unchecked string, and a wrong
        /// one draws an empty button.
        @Test func theComposerSymbolsExist() {
            let symbols = [
                ComposerLayout.attachSymbol, ComposerLayout.emojiSymbol,
                ComposerLayout.dictationSymbol, ComposerLayout.saveSymbol
            ]
            for symbol in symbols {
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            }
        }

        /// One line is a capsule: the corners take the whole height.
        @Test func aOneLineFieldIsACapsule() {
            let line = CGRect(x: 0, y: 0, width: 300, height: 31)
            let path = ComposerLayout.fieldShape.path(in: line)
            #expect(!path.contains(CGPoint(x: 2, y: 2)))
            #expect(path.contains(CGPoint(x: 2, y: 15.5)))
        }
    }
#endif
