#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The bubble's menu keeps its content whether or not it offers anything.
    /// It drew `content` in one branch and `content.contextMenu` in another,
    /// so a send finishing or reactions arriving rebuilt the whole bubble
    /// under it, text view and all - the `FileDropTarget` failure again.
    @MainActor
    struct ReactionMenuStructureTests {
        final class Appearances {
            var count = 0
        }

        struct Hosted: View {
            let appearances: Appearances
            let message: Message
            let actions: ReactionActions?
            let own: OwnMessageMenuItems?

            var body: some View {
                Text("bubble")
                    .onAppear { appearances.count += 1 }
                    .modifier(ReactionMenu(message: message, actions: actions, own: own))
            }
        }

        private static let message = Message(
            id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID("t-1"), sender: Member.ID("u-me"), text: "hello",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        private func settle(_ host: NSView) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }

        @Test func turningTheMenuOffAndOnKeepsTheBubble() {
            let appearances = Appearances()
            let reactions = ReactionActions { _, _, _ in }
            let own = OwnMessageMenuItems(edit: {}, delete: {})
            func hosted(
                _ actions: ReactionActions?,
                _ own: OwnMessageMenuItems?,
                deleted: Bool = false
            ) -> Hosted {
                var message = Self.message
                message.isDeleted = deleted
                return Hosted(appearances: appearances, message: message, actions: actions, own: own)
            }
            let host = NSHostingView(rootView: hosted(reactions, own))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = host
            settle(host)
            // The positive control: the content did appear.
            #expect(appearances.count == 1)
            struct Flip {
                let actions: ReactionActions?
                let own: OwnMessageMenuItems?
                var deleted = false
            }
            for flip in [
                Flip(actions: nil, own: nil), Flip(actions: reactions, own: nil), Flip(
                    actions: nil,
                    own: own
                ),
                Flip(actions: reactions, own: own, deleted: true), Flip(actions: reactions, own: own)
            ] {
                host.rootView = hosted(flip.actions, flip.own, deleted: flip.deleted)
                settle(host)
            }
            #expect(appearances.count == 1)
            withExtendedLifetime(window) {}
        }
    }
#endif
