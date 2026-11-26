#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// Hidden renders of the panes, sheets and settings sections that came
    /// with starring, scheduling, sections and blocking. Nothing is ordered
    /// front; a PNG is written only where `KIBBLE_CHAT_ADDITIONS_RENDER_DIR`
    /// names a folder.
    @MainActor @Suite(.serialized)
    struct ChatAdditionsRenderTests {
        private let conversation = Conversation(id: .init("design"), kind: .space, title: "Design Team")
        private let sender = Member(id: .init("person"), kind: .human, displayName: "Casey Lee")

        @Test func savedSenderFallsBackWhenThePageIncludesOnlyAnID() {
            var state = ChatSceneState(directory: [sender.id: sender], me: sender.id)
            state.stars.members[sender.id] = Member(id: sender.id, kind: .human)
            #expect(StarredPresentation.senderName(for: sender.id, in: state) == "Casey Lee")
            state.directory = [:]
            #expect(StarredPresentation.senderName(for: sender.id, in: state) == "You")
            #expect(StarredPresentation.senderName(for: .init("unknown"), in: state) == "Unknown sender")
        }

        @Test(arguments: [false, true])
        func unreadPaneRendersConversationGroups(_ dark: Bool) async throws {
            let launch = Conversation(id: .init("launch"), kind: .space, title: "Launch Team")
            let jordan = Member(id: .init("jordan"), kind: .human, displayName: "Jordan Rivera")
            var state = ChatSceneState(
                conversations: [conversation, launch], directory: [sender.id: sender, jordan.id: jordan]
            )
            let time = Date(timeIntervalSince1970: 1_800_000_000)
            state.unread.showing = true
            state.unread.badgeConversations = [conversation.id, launch.id]
            state.unread.messages = [
                Message(
                    id: .init("notes"), conversationID: conversation.id, threadID: .init("review"),
                    sender: sender.id, text: "The new mockups are ready for review.", createdAt: time
                ),
                Message(
                    id: .init("feedback"), conversationID: conversation.id, threadID: .init("review"),
                    sender: jordan.id, text: "I left feedback on the sidebar and the empty state.",
                    createdAt: time.addingTimeInterval(120), isReply: true
                ),
                Message(
                    id: .init("checklist"), conversationID: launch.id, threadID: .init("plan"),
                    sender: jordan.id, text: "The launch checklist is ready for tomorrow’s walkthrough.",
                    createdAt: time.addingTimeInterval(240)
                )
            ]
            let actions = UnreadActions(
                show: {}, retry: {}, markMessageRead: { _ in }, markRead: { _, _ in },
                markAllRead: { _ in }
            )
            try await render(
                UnreadPane(state: state, actions: actions, open: { _ in }),
                size: CGSize(width: 600, height: 320), dark: dark, name: "unread"
            )
            var sidebar = ChatSceneActions(showMentions: {})
            sidebar.unread = actions
            state.unread.showing = false
            state.unreadMentionCount = 3
            try await render(
                ConversationList(state: state, actions: sidebar),
                size: CGSize(width: 240, height: 290), dark: dark, name: "unread-sidebar"
            )
        }

        @Test(arguments: [false, true])
        func scheduledAndStarredPanesRender(_ dark: Bool) async throws {
            let time = Date(timeIntervalSince1970: 1_800_000_000)
            var state = ChatSceneState(conversations: [conversation], directory: [sender.id: sender])
            state.scheduled.messages = [
                ScheduledMessage(
                    id: .init(conversation: conversation.id, thread: nil, queueID: "file"),
                    body: .init(text: ""), deliveryTime: time, attachmentNames: ["Design.pdf", "Preview.png"]
                ),
                ScheduledMessage(
                    id: .init(conversation: conversation.id, thread: nil, queueID: "text"),
                    body: ComposedMessage(text: "Share the final design notes after the review."),
                    deliveryTime: time.addingTimeInterval(7200), deliveryFailed: true
                )
            ]
            state.scheduled.readFailed = true
            let scheduled = ScheduledMessagesActions(
                show: {}, refresh: {}, loadMore: {}, submit: { _, _, _, _ in true },
                latestReceipt: { _ in nil }, edit: { _, _, _ in true },
                reschedule: { _, _, _ in true }, cancel: { _ in }, sendNow: { _ in }
            )
            try await render(
                ScheduledMessagesPane(state: state, actions: scheduled),
                size: CGSize(width: 460, height: 300), dark: dark, name: "scheduled"
            )
            state.stars.messages = [
                Message(
                    id: .init("star"), conversationID: conversation.id, threadID: .init("thread"),
                    sender: sender.id, text: "Share the final design notes after the review.",
                    createdAt: time
                ),
                Message(
                    id: .init("star2"), conversationID: .init("gone"), threadID: .init("thread"),
                    sender: .init("stranger"), text: "A message from a conversation that is not listed.",
                    createdAt: time.addingTimeInterval(-86400)
                )
            ]
            state.stars.hasMore = true
            let stars = StarredMessagesActions(show: {}, refresh: {}, loadMore: {}, set: { _, _ in })
            try await render(
                StarredMessagesPane(state: state, actions: stars, open: { _ in }),
                size: CGSize(width: 460, height: 300), dark: dark, name: "starred"
            )
            var empty = ChatSceneState()
            empty.stars.readFailed = true
            try await render(
                HStack(spacing: 0) {
                    StarredMessagesPane(state: empty, actions: stars, open: nil)
                    ScheduledMessagesPane(state: ChatSceneState(), actions: scheduled)
                },
                size: CGSize(width: 700, height: 260), dark: dark, name: "empty-panes"
            )
        }

        @Test(arguments: [false, true])
        func sheetsRender(_ dark: Bool) async throws {
            try await render(
                ScheduledDateSheet(
                    title: "Reschedule Message", confirm: "Reschedule",
                    initial: Date(timeIntervalSince1970: 1_800_000_000), cancel: {}, save: { _ in },
                    failed: true
                ),
                size: nil, dark: dark, name: "date-sheet"
            )
            let section = ConversationSection(
                id: "work", name: "Work", conversationIDs: [], sort: .name, unreadOnly: true
            )
            try await render(
                ConversationSectionEditor(section: section, save: { _ in }, delete: { _ in }),
                size: nil, dark: dark, name: "section-edit"
            )
            try await render(
                ConversationSectionEditor(create: { _ in }), size: nil, dark: dark, name: "section-create"
            )
        }

        @Test(arguments: [false, true])
        func settingsRender(_ dark: Bool) async throws {
            let resolved = NotificationRule.resolve([])
            let rules = ConversationRuleState(
                id: .init("space"), title: "Design", rule: NotificationRule(),
                inherited: resolved, resolved: resolved
            )
            try await render(
                ConversationNotificationSheet(
                    state: rules,
                    spaceNotifications: .init(level: .lessWithNewThreads, muted: true, canSave: true) { _ in
                    },
                    conversationMute: .init(
                        pause: .until(Date(timeIntervalSinceNow: 3600)), canSave: true
                    ) { _ in }
                ) { _ in },
                size: CGSize(width: 480, height: 620), dark: dark, name: "notifications"
            )
            try await render(
                privacy(rooms: [.init(id: .init("room"), name: "Fixture Room")], error: "Couldn’t unblock."),
                size: CGSize(width: 560, height: 360), dark: dark, name: "privacy"
            )
            try await render(
                privacy(rooms: [], error: nil), size: CGSize(width: 560, height: 360), dark: dark,
                name: "privacy-empty"
            )
        }

        @Test func emptyAndStatusLinesSayWhatIsSo() {
            typealias Copy = BlockedListCopy
            #expect(Copy.placeholder(
                .people, hasRows: true, isAvailable: true, isLoading: false, failed: false
            ) == nil)
            #expect(Copy.placeholder(
                .people, hasRows: false, isAvailable: false, isLoading: true, failed: false
            ) == "Not connected.")
            #expect(Copy.placeholder(
                .people, hasRows: false, isAvailable: true, isLoading: true, failed: false
            ) == "Loading…")
            #expect(Copy.placeholder(
                .conversations, hasRows: false, isAvailable: true, isLoading: false, failed: true
            ) == "Couldn’t load blocked conversations.")
            #expect(Copy.placeholder(
                .people, hasRows: false, isAvailable: true, isLoading: false, failed: false
            ) == "No blocked people.")
            #expect(ConversationMuteSection.status(.off, muted: false) == "Off")
            #expect(ConversationMuteSection.status(.untilResumed, muted: true) == "Until I Unmute")
            #expect(ConversationMuteSection.status(.until(.distantFuture), muted: true).hasPrefix("Until "))
            let address = ScheduledMessageAddress(conversation: conversation.id, thread: nil, queueID: "q")
            let files = ScheduledMessage(
                id: address, body: .init(text: ""), deliveryTime: .now, attachmentNames: ["A.pdf"]
            )
            #expect(ScheduledPresentation.body(of: files) == nil)
            let words = ScheduledMessage(id: address, body: .init(text: "Hello"), deliveryTime: .now)
            #expect(ScheduledPresentation.body(of: words) == "Hello")
        }

        private func privacy(rooms: [BlockedConversation], error: String?) -> some View {
            PrivacySettingsPane(
                conversations: .init(
                    state: .init(
                        rows: rooms,
                        isAvailable: true,
                        isLoading: false,
                        pending: nil,
                        error: error
                    ),
                    actions: .init(refresh: {}, unblock: { _ in })
                ),
                people: .init(
                    state: .init(
                        rows: [
                            .init(id: .init("person"), name: "Fixture Person"),
                            .init(id: .init("other"), name: "Another Person")
                        ],
                        isAvailable: true, isLoading: false, pending: .init("other"), error: nil
                    ),
                    actions: .init(refresh: {}, unblock: { _ in })
                )
            )
        }

        /// `size` nil lets the view take its own size, as a sheet does.
        private func render(_ view: some View, size: CGSize?, dark: Bool, name: String) async throws {
            let root = view
                .frame(width: size?.width, height: size?.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame.size = size ?? host.fittingSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: host.frame.size), styleMask: [],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            for _ in 0 ..< 6 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(host.frame.width >= 200 && host.frame.height >= 100)
            guard let directory = ProcessInfo.processInfo.environment["KIBBLE_CHAT_ADDITIONS_RENDER_DIR"]
            else { return }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }
#endif
