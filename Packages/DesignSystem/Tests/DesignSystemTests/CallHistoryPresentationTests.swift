#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The Calls list: what a row says, what the pane shows in each state,
    /// where the row is offered, and how the window and the menu bar reach it.
    @MainActor
    struct CallHistoryPresentationTests {
        private let me = Member.ID("users/me")
        private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
        private let space = Conversation(id: Conversation.ID("space/s"), kind: .space, title: "Design")
        private let date = Date(timeIntervalSince1970: 1_600_000_000)

        private func record(
            _ status: MessageCallStatus?,
            from sender: Member.ID,
            id: String = "c:1"
        ) -> Message {
            Message(
                id: Message.ID(id), conversationID: space.id, threadID: MessageThread.ID("t"),
                sender: sender, text: "", createdAt: date, callStatus: status
            )
        }

        private func item(
            _ status: MessageCallStatus,
            from sender: Member.ID,
            id: String = "c:1"
        ) -> CallHistoryItem {
            CallHistoryItem(
                message: record(status, from: sender, id: id), conversation: space,
                directory: [alice.id: alice], me: me
            )
        }

        private func actions(_ log: Log = Log()) -> CallHistoryActions {
            CallHistoryActions(
                show: { log.calls.append("show") }, loadMore: { log.calls.append("more") },
                retry: { log.calls.append("retry") }, open: { log.calls.append("open \($1.rawValue)") }
            )
        }

        private final class Log {
            var calls: [String] = []
        }

        @Test func aRowNamesTheConversationTheCardsWordsAndWhoPostedIt() {
            let missed = item(.missed, from: alice.id)
            #expect(missed.conversationTitle == "Design")
            #expect(CallHistoryPresentation.statusTitle(missed.status) == "Call missed")
            #expect(missed.senderName == "Alice")
            #expect(item(.ended, from: me).senderName == "You")
            #expect(CallHistoryPresentation.statusTitle(.started) == "Call started")
            #expect(CallHistoryPresentation.statusTitle(.ended) == "Call ended")
            #expect(CallHistoryPresentation.statusTitle(.unknown("future")) == "Call activity")
        }

        /// A record whose conversation is no longer listed keeps its row, under
        /// a neutral name, rather than vanishing from history.
        @Test func aRecordOutsideTheListedConversationsKeepsANeutralName() {
            let row = CallHistoryItem(
                message: record(.ended, from: alice.id),
                conversation: nil,
                directory: [:],
                me: me
            )
            #expect(row.conversation == nil)
            #expect(row.conversationTitle == "Conversation")
            #expect(CallHistoryItem(
                message: record(nil, from: alice.id), conversation: space, directory: [:], me: me
            ).status == .unknown(""))
        }

        @Test func thePaneSpeaksOnlyForAnEmptyList() {
            #expect(CallHistoryPresentation.content(CallHistoryScene()) == .loading)
            #expect(CallHistoryPresentation.content(CallHistoryScene(status: .loading)) == .loading)
            #expect(CallHistoryPresentation.content(CallHistoryScene(status: .loaded)) == .empty)
            #expect(CallHistoryPresentation.content(CallHistoryScene(status: .failed)) == .failed)
            let rows = [item(.ended, from: me)]
            #expect(CallHistoryPresentation
                .content(CallHistoryScene(items: rows, status: .loading)) == .items)
            #expect(CallHistoryPresentation.content(CallHistoryScene(items: rows, status: .loaded)) == .items)
        }

        /// The list never claims to be every call ever made.
        @Test func theCopyStatesWhatTheListCoversAndNamesNoProvider() {
            let copy = [
                CallHistoryPresentation.coverageText, CallHistoryPresentation.emptyText,
                CallHistoryPresentation.failedText, CallHistoryPresentation.loadMoreFailedText
            ]
            #expect(copy.allSatisfy { !$0.contains("Google") && !$0.contains("Meet") })
            #expect(CallHistoryPresentation.coverageText.contains("this account"))
        }

        @Test func theRowSymbolExists() {
            #expect(NSImage(
                systemSymbolName: CallHistoryPresentation.rowSymbol,
                accessibilityDescription: nil
            ) != nil)
            for status in CallMessageCard.statuses {
                #expect(NSImage(
                    systemSymbolName: CallMessageCard.symbol(of: status),
                    accessibilityDescription: nil
                ) != nil)
            }
        }

        @Test func theCallsRowFollowsThreadsAndOnlyWhereTheHostOffersIt() {
            var offered = ChatSceneActions(showMentions: {}, search: .inert)
            offered.callHistory = actions()
            #expect(SidebarPinned.rows(offered) == [.search, .mentions, .calls])
            #expect(!SidebarPinned.rows(ChatSceneActions(showMentions: {})).contains(.calls))
        }

        @Test func choosingCallsShowsTheListAndSelectsTheRow() {
            let log = Log()
            var actions = ChatSceneActions()
            actions.callHistory = self.actions(log)
            SidebarPinned.choose(.calls, actions: actions)
            #expect(log.calls == ["show"])
            var state = ChatSceneState()
            state.callHistory.showingList = true
            #expect(state.sidebarSelection == .calls)
            #expect(SidebarPinned.pinnedSelection(state) == .calls)
            #expect(SidebarPinned.conversationSelection(state) == nil)
        }

        @Test func theMenuBarOffersGoToCallsWhereTheRowIs() throws {
            let log = Log()
            var actions = ChatSceneActions()
            actions.callHistory = self.actions(log)
            let entries = ConversationMenuBar(state: ChatSceneState(), actions: actions).sections
                .flatMap(\.self)
            let entry = try #require(entries.first { $0.id == "calls" })
            #expect(entry.title == "Go to Calls")
            try ConversationMenuBar.perform(#require(entry.command), actions: actions)
            #expect(log.calls == ["show"])
            let without = ConversationMenuBar(state: ChatSceneState(), actions: ChatSceneActions())
            #expect(!without.sections.flatMap(\.self).contains { $0.id == "calls" })
        }

        @Test func theWindowIsTitledCallsWhileTheListShows() {
            var state = ChatSceneState()
            state.callHistory.showingList = true
            var actions = ChatSceneActions()
            actions.callHistory = self.actions()
            #expect(ChatWindow(state: state, actions: actions).title == "Calls")
        }

        /// Opt-in render for looking at the rows; set the directory to write
        /// PNGs. A `List` does not render offscreen, so the rows are drawn alone.
        @Test func rowsRenderInLightAndDark() throws {
            let rows = [
                item(.missed, from: alice.id, id: "c:3"), item(.started, from: me, id: "c:2"),
                item(.ended, from: alice.id, id: "c:1")
            ]
            for dark in [false, true] {
                let preview = VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        CallHistoryRow(
                            item: row, directory: [alice.id: alice], me: me,
                            now: date.addingTimeInterval(3600),
                            callBack: index == 1 ? nil : {}
                        )
                        .padding(.horizontal, 12)
                        Divider()
                    }
                    CallHistoryFooter(scene: CallHistoryScene(
                        items: rows,
                        status: .loaded,
                        loadMoreFailed: true
                    )) {}
                        .padding(12)
                }
                .frame(width: 520).background(.background)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: preview)
                host.frame.size = host.fittingSize
                let window = NSWindow(
                    contentRect: host.frame,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                #expect(host.frame.height > 120)
                if let output = ProcessInfo.processInfo.environment["KIBBLE_CALL_HISTORY_RENDER_DIR"] {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: output)
                        .appendingPathComponent("call-history-\(dark ? "dark" : "light").png"))
                }
                withExtendedLifetime(window) {}
            }
        }

        /// Opt-in: the whole pane, `List` included, in a hosted window, and its
        /// empty and failed overlays.
        @Test func thePaneRendersInAHostedWindow() throws {
            guard let output = ProcessInfo.processInfo.environment["KIBBLE_CALL_HISTORY_RENDER_DIR"]
            else { return }
            let rows = [item(.missed, from: alice.id, id: "c:2"), item(.ended, from: me, id: "c:1")]
            let scenes: [(String, CallHistoryScene)] = [
                ("items", CallHistoryScene(showingList: true, items: rows, status: .loaded)),
                ("empty", CallHistoryScene(showingList: true, status: .loaded)),
                ("failed", CallHistoryScene(showingList: true, status: .failed))
            ]
            for (name, scene) in scenes {
                let pane = CallHistoryPane(
                    scene: scene, directory: [alice.id: alice], me: me, callable: [space.id],
                    actions: actions(), call: { _ in }
                )
                .frame(width: 560, height: 320)
                let host = NSHostingView(rootView: pane)
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 320)
                let window = NSWindow(
                    contentRect: host.frame,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("pane-\(name).png"))
                withExtendedLifetime(window) {}
            }
        }
    }
#endif
