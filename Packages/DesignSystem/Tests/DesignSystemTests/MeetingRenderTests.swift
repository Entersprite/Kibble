#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.serialized)
    struct MeetingRenderTests {
        @Test func nativeMeetingTranscriptAtNarrowAndRegularWidths() async throws {
            let state = fixture()
            let actions = ChatSceneActions(select: { _ in }, send: { _ in })
            #expect(ChatWindow(state: state, actions: actions).title == "Weekly Planning")
            let series = try #require(state.meetingSeries)
            for width in [CGFloat(320), CGFloat(540)] {
                for dark in [false, true] {
                    let preview = VStack(spacing: 0) {
                        MeetingSeriesRow(series: series, state: state).padding(12)
                        Divider()
                        MessageList(state: state)
                        Divider()
                        Composer(placeholder: series.title, send: { _ in }).padding(12)
                    }
                    .frame(width: width, height: 580).background(.background)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    try await render(preview, width: width, dark: dark)
                }
            }
        }

        @Test func firstSyncIndicatorInSidebarAndDirectory() async throws {
            var state = fixture()
            state.isLoadingMeetingMetadata = true
            state.browser.page = "meetChat"
            let actions = ChatSceneActions(select: { _ in }, send: { _ in })
            for dark in [false, true] {
                let preview = HStack(spacing: 0) {
                    ConversationList(state: state, actions: actions).frame(width: 260)
                    Divider()
                    ConversationDirectoryView(state: state, actions: actions).frame(width: 539)
                }
                .frame(width: 800, height: 580)
                .environment(\.colorScheme, dark ? .dark : .light)
                try await render(preview, width: 800, dark: dark, name: "meeting-first-sync")
            }
        }

        @Test func mixedMeetingRowsAtNarrowAndRegularWidths() async throws {
            var state = fixture()
            state.selected = nil
            state.selectedMeetingSeries = nil
            state.browser.page = "meetChat"
            state.conversations += [
                Conversation(
                    id: .init("one-off"),
                    kind: .meetChat,
                    title: "Self serve onboarding QA session (optional for most invitees) - Oct 13",
                    lastActivity: Date(timeIntervalSince1970: 1_791_791_999),
                    memberCount: 8
                ),
                Conversation(
                    id: .init("unknown-members"),
                    kind: .meetChat,
                    title: "Scheduler - Oct 6",
                    lastActivity: Date(timeIntervalSince1970: 1_791_100_000)
                ),
                Conversation(
                    id: .init("unread-one-off"),
                    kind: .meetChat,
                    title: "Engineering review - Oct 5",
                    lastActivity: Date(timeIntervalSince1970: 1_791_000_000),
                    hasUnread: true,
                    memberCount: 9
                )
            ]
            let actions = ChatSceneActions(select: { _ in }, send: { _ in })
            for width in [CGFloat(620), CGFloat(900)] {
                for dark in [false, true] {
                    let preview = HStack(spacing: 0) {
                        ConversationList(state: state, actions: actions).frame(width: 220)
                        Divider()
                        ConversationDirectoryView(state: state, actions: actions).frame(width: width - 221)
                    }
                    .frame(width: width, height: 580)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    try await render(preview, width: width, dark: dark, name: "meeting-directory")
                }
            }
            let series = try #require(MeetingSeries.build(state.conversations).first)
            let grouped = NSHostingView(rootView: DirectoryConversationRow(
                item: .meeting(series),
                state: state
            ))
            let single = NSHostingView(rootView: DirectoryConversationRow(
                item: .conversation(state.conversations[2]), state: state
            ))
            #expect(abs(grouped.fittingSize.height - single.fittingSize.height) < 1)
        }

        private func fixture() -> ChatSceneState {
            let me = Member.ID("me")
            let other = Member.ID("other")
            let start = Date(timeIntervalSince1970: 1_791_878_400)
            let conversations: [Conversation] = (0 ..< 2).map { index in
                Conversation(
                    id: .init("meeting-\(index)"), kind: .meetChat, title: "Weekly Planning - occurrence",
                    lastActivity: start.addingTimeInterval(Double(index) * 86400 + 120),
                    members: [me, other], memberCount: 12,
                    meeting: MeetingOccurrence(
                        seriesID: .init("planning"), occurrenceID: "occurrence-\(index)",
                        seriesTitle: "Weekly Planning",
                        scheduledStart: start.addingTimeInterval(Double(index) * 86400)
                    )
                )
            }
            let messages: [Message] = conversations.enumerated().flatMap { ordinal, conversation in
                (0 ..< 2).map { index in
                    Message(
                        id: .init("\(conversation.id)-\(index)"), conversationID: conversation.id,
                        threadID: .init("topic-\(conversation.id)-\(index)"), sender: index == 0 ? other : me,
                        text: index == 0 ? "Sharing the plan for this week." :
                            "Thanks. I’ll follow up after the meeting.",
                        createdAt: start.addingTimeInterval(Double(ordinal) * 86400 + Double(index) * 60)
                    )
                }
            }
            var state = ChatSceneState(
                conversations: conversations,
                directory: [
                    me: Member(id: me, kind: .human, displayName: "You"),
                    other: Member(id: other, kind: .human, displayName: "Alex")
                ],
                me: me, selected: conversations[1].id, messages: messages,
                capabilities: Capabilities(canSendMessages: true)
            )
            state.selectedMeetingSeries = MeetingSeries.ID("title:Weekly Planning")
            return state
        }

        private func render(
            _ preview: some View,
            width: CGFloat,
            dark: Bool,
            name: String = "meetings"
        ) async throws {
            let host = NSHostingView(rootView: preview)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 580)
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.orderFront(nil)
            for _ in 0 ..< 10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(host.frame.width == width)
            if let output = ProcessInfo.processInfo.environment["KIBBLE_MEETING_RENDER_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(
                    "\(name)-\(Int(width))-\(dark ? "dark" : "light").png"
                ))
            }
            window.close()
        }
    }
#endif
