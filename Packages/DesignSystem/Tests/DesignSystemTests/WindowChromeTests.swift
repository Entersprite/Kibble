#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The window's bars and buttons: the measures their shapes are built on,
    /// and the names their menus draw. Their look is the owner's screenshot.
    @MainActor
    struct WindowChromeTests {
        private func threads() -> ThreadActions {
            ThreadActions(
                open: { _ in }, close: {}, sendReply: { _ in }, setFollowed: { _ in },
                markUnread: { _ in }, showList: {}, openItem: { _, _ in }
            )
        }

        /// An SF Symbol name is an unchecked string: a wrong one renders as
        /// empty space (`CLAUDE.md`).
        @Test func everyDirectoryMenuSymbolExists() {
            for name in DirectoryMenuSymbols.all + ["exclamationmark.triangle.fill"] {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
            #expect(Set(DirectoryMenuSymbols.all).count == DirectoryMenuSymbols.all.count)
        }

        /// Follow is the system's glass button, as tall as Close beside it in
        /// either state.
        @Test func followIsAsTallAsClose() {
            for followed in [false, true] {
                let panel = ThreadPanelState(
                    thread: MessageThread(id: .init("t"), conversationID: .init("c"), isFollowed: followed),
                    conversationTitle: "Deploys"
                )
                let follow = NSHostingView(rootView: ThreadFollowButton(panel: panel, threads: threads()))
                let close = NSHostingView(rootView: ThreadCloseButton(threads: threads()))
                #expect(follow.fittingSize.height == close.fittingSize.height)
                #expect(follow.fittingSize.height == ComposerLayout.lineHeight)
            }
        }

        /// A one-line bar is a capsule: its corner is half its height. The
        /// strip and the results bar are the same height with buttons, and a
        /// line of words alone is shorter, where the corner is clamped round.
        @Test func aOneLineBarIsACapsule() {
            var actions = ChatSceneActions()
            actions.signIn = {}
            let warning = NSHostingView(rootView: StatusStrip(
                state: ChatSceneState(connection: .connecting, lastError: .notAuthenticated), actions: actions
            ).frame(width: 640))
            let bar = NSHostingView(rootView: SearchResultsBar(
                bar: SearchBarScene(query: MessageSearchQuery(text: "deploy"), index: 0, count: 3),
                state: ChatSceneState(), actions: .inert
            ).frame(width: 640))
            let progress = NSHostingView(rootView: StatusStrip(
                state: ChatSceneState(connection: .connecting), actions: actions
            ).frame(width: 640))
            // The bars' outer padding is 6 points above and below the glass.
            let glassHeight = warning.fittingSize.height - 12
            #expect(glassHeight == ContentBarLayout.cornerRadius * 2)
            #expect(bar.fittingSize.height == warning.fittingSize.height)
            #expect(progress.fittingSize.height - 12 <= ContentBarLayout.cornerRadius * 2)
        }

        /// A narrow column wraps a warning's words and puts its buttons under
        /// them, rather than truncating either.
        @Test func aNarrowColumnStacksAWarningsButtons() {
            var actions = ChatSceneActions()
            actions.signIn = {}
            actions.reconnect = {}
            let state = ChatSceneState(connection: .reconnecting(
                attempt: 1,
                issue: .intercepted,
                detail: nil
            ))
            let wide = NSHostingView(rootView: StatusStrip(state: state, actions: actions).frame(width: 1000))
            let narrow = NSHostingView(rootView: StatusStrip(state: state, actions: actions)
                .frame(width: 300))
            #expect(narrow.fittingSize.height > wide.fittingSize.height)
            #expect(wide.fittingSize.height - 12 == ContentBarLayout.cornerRadius * 2)
        }
    }
#endif
