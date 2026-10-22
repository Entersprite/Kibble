#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor @Suite(.serialized)
    struct ConversationPanelsHostedTests {
        private var actions: ConversationBrowserActions {
            ConversationBrowserActions(
                show: { _ in },
                back: {},
                search: { _, _, _ in },
                reviewCreation: {},
                searchPeople: { _ in },
                beginCreation: { _ in },
                create: { _ in },
                closePanel: {},
                details: { _, _ in },
                preview: { _ in },
                mutate: { _ in }
            )
        }

        @Test func smallCreationAndManagementPanelsRenderInBothAppearances() async throws {
            let people = (1 ... 8).map {
                Member(
                    id: .init("person-\($0)"),
                    kind: .human,
                    displayName: "Person \($0)",
                    email: "person\($0)@example.test"
                )
            }
            var state =
                ChatSceneState(directory: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) }))
            state.browser.creationKind = .space
            var sceneActions = ChatSceneActions()
            sceneActions.browser = actions
            sceneActions.updateSidebar = { _ in }
            for dark in [false, true] {
                try await render(
                    ConversationPanelSheet(state: state, browser: actions, openNotifications: { _ in }),
                    dark: dark,
                    name: "creation-\(dark ? "dark" : "light")",
                    size: NSSize(width: 480, height: 560)
                )
            }
            state.browser.creationKind = nil
            state.browser.panelTarget = .init("space")
            state.browser.details = ConversationDetails(
                conversation: Conversation(id: .init("space"), kind: .space, title: "Design Team"),
                description: "Product ideas and weekly reviews", membership: .joined,
                allowedActions: ["identity", "rename", "description", "leave", "deleteSpace", "addPeople"]
            )
            for dark in [false, true] {
                try await render(
                    ConversationPanelSheet(state: state, browser: actions, openNotifications: { _ in }),
                    dark: dark,
                    name: "management-\(dark ? "dark" : "light")",
                    size: NSSize(width: 520, height: 580)
                )
            }
            try await renderPeopleAndPreview(state, people: people)
        }

        private func renderPeopleAndPreview(_ initial: ChatSceneState, people: [Member]) async throws {
            var state = initial
            state.browser.participants = people.prefix(4).enumerated().map { index, person in
                ConversationParticipant(
                    member: person,
                    role: index == 0 ? .owner : .member,
                    state: index == 3 ? .invited : .joined,
                    allowedActions: index == 0 ? [] : ["setRole", "removePerson"],
                    allowedRoles: [.member, .manager]
                )
            }
            let details = try #require(state.browser.details)
            try await render(
                ConversationPeopleForm(details: details, state: state, actions: actions) { _ in },
                dark: false,
                name: "management-people",
                size: NSSize(width: 520, height: 460)
            )
            state.browser.details = ConversationDetails(
                conversation: Conversation(
                    id: .init("open"),
                    kind: .space,
                    title: "Coffee Break",
                    memberCount: 42
                ),
                description: "Everything but work",
                membership: .unknown,
                allowedActions: ["join"],
                previewMessages: [Message(
                    id: .init("m1"), conversationID: .init("open"), threadID: .init("t1"),
                    sender: people[0].id,
                    text: "Anyone up for a coffee at three?", createdAt: Date(timeIntervalSince1970: 0)
                )]
            )
            try await render(
                ConversationPanelSheet(state: state, browser: actions, openNotifications: nil),
                dark: false,
                name: "management-preview",
                size: NSSize(width: 520, height: 580)
            )
            try await renderLoadedPreview(state, people: people)
        }

        private func renderLoadedPreview(_ initial: ChatSceneState, people: [Member]) async throws {
            var state = initial
            state.browser.details?.allowedActions = ["acceptInvitation", "block"]
            state.browser.details?.membership = .invited
            let room = try #require(state.browser.details?.conversation.id)
            state.browser.preview = ConversationPreview(
                messages: people.prefix(3).enumerated().map { index, person in
                    Message(
                        id: .init("preview-\(index)"),
                        conversationID: room,
                        threadID: .init("topic-\(index)"),
                        sender: person.id,
                        text: [
                            "Welcome to the space!",
                            "The weekly notes are ready to read.",
                            "Thanks, I’ll take a look."
                        ][index],
                        createdAt: Date(timeIntervalSince1970: Double(index) * 3600)
                    )
                },
                members: people
            )
            for dark in [false, true] {
                try await render(
                    ConversationPanelSheet(state: state, browser: actions, openNotifications: nil),
                    dark: dark, name: "loaded-space-preview-\(dark ? "dark" : "light")",
                    size: NSSize(width: 560, height: 560)
                )
            }
        }

        @Test func sidebarSettingsAndSpacesDirectoryRender() async throws {
            let conversations = (1 ... 14).map {
                Conversation(id: .init("chat-\($0)"), kind: .directMessage, title: "Person \($0)")
            } + [
                Conversation(id: .init("design"), kind: .space, title: "Design Team"),
                Conversation(id: .init("group"), kind: .groupDirectMessage, title: "Launch Planning"),
                Conversation(id: .init("app"), kind: .appDirectMessage, title: "Calendar"),
                Conversation(id: .init("meet"), kind: .meetChat, title: "Weekly Review")
            ]
            var state = ChatSceneState(conversations: conversations)
            state.browser.page = "space"; state.browser.lastPage = "space"
            state.browser.scope = .all
            state.browser.spaces = [ConversationDetails(conversation: conversations[14], membership: .joined)]
            var sceneActions = ChatSceneActions()
            sceneActions.browser = actions
            sceneActions.updateSidebar = { _ in }
            sceneActions.showDirectory = { _ in }
            try await renderDirectoryPages(state, actions: sceneActions)
            state.sidebarPreferences.update(.init(id: "directMessage", maximumItems: 3))
            for dark in [false, true] {
                try await render(
                    ConversationList(state: state, actions: sceneActions).frame(width: 300),
                    dark: dark,
                    name: "sidebar-\(dark ? "dark" : "light")"
                )
            }
            try await render(
                SidebarSettingsPane(preferences: .init(), update: { _ in }),
                dark: false,
                name: "sidebar-settings",
                size: NSSize(width: 560, height: 540)
            )
        }

        @Test func favoritesRenderAboveOtherSectionsWithMixedRowsAndNoDirectory() async throws {
            let chats = [
                Conversation(id: .init("dm"), kind: .directMessage, title: "Alex Lee"),
                Conversation(id: .init("space"), kind: .space, title: "Design Team"),
                Conversation(id: .init("app"), kind: .appDirectMessage, title: "Calendar"),
                Conversation(id: .init("group"), kind: .groupDirectMessage, title: "Launch Planning")
            ]
            var state = ChatSceneState(conversations: chats)
            state.sidebarPreferences = SidebarPreferences(favoriteConversations: Set(chats.map(\.id)))
            var sceneActions = ChatSceneActions()
            sceneActions.updateSidebar = { _ in }
            sceneActions.showDirectory = { _ in }
            for dark in [false, true] {
                try await render(
                    ConversationList(state: state, actions: sceneActions).frame(width: 280),
                    dark: dark, name: "favorites-\(dark ? "dark" : "light")",
                    size: NSSize(width: 280, height: 760)
                )
            }
            try await render(
                SidebarSettingsPane(preferences: state.sidebarPreferences, update: { _ in }),
                dark: false, name: "favorites-settings", size: NSSize(width: 560, height: 780)
            )
        }

        private func renderDirectoryPages(
            _ initial: ChatSceneState,
            actions sceneActions: ChatSceneActions
        ) async throws {
            var state = initial
            try await render(
                ConversationDirectoryView(state: state, actions: sceneActions),
                dark: false,
                name: "spaces-directory"
            )
            state.browser.scope = .discover
            state.browser.spaces += [
                ConversationDetails(conversation: Conversation(
                    id: .init("outside"),
                    kind: .space,
                    title: "Coffee Break"
                )),
                ConversationDetails(conversation: state.conversations[17])
            ]
            try await render(
                ConversationDirectoryView(state: state, actions: sceneActions),
                dark: false,
                name: "spaces-discover"
            )
            try await renderSuggestionsAndSpam(state, actions: sceneActions)
            for page in ["appDirectMessage", "meetChat"] {
                state.browser.page = page; state.browser.lastPage = page
                try await render(
                    ConversationDirectoryView(state: state, actions: sceneActions),
                    dark: false,
                    name: "\(page)-directory"
                )
            }
            state.browser.page = "people"; state.browser.lastPage = "people"
            let person = Member(id: .init("ava"), kind: .human, displayName: "Ava", email: "ava@example.test")
            state.directory[person.id] = person
            try await render(
                ConversationDirectoryView(state: state, actions: sceneActions),
                dark: false,
                name: "people-directory"
            )
        }

        private func renderSuggestionsAndSpam(
            _ initial: ChatSceneState, actions sceneActions: ChatSceneActions
        ) async throws {
            var state = initial
            state.browser.spaces += (1 ... 6).map { index in
                ConversationDetails(conversation: Conversation(
                    id: .init("suggestion-\(index)"), kind: .space,
                    title: "Suggested Space \(index)", memberCount: index + 3
                ), description: "A place for shared ideas.", linkedGroupCount: 1)
            }
            for dark in [false, true] {
                try await render(
                    ConversationDirectoryView(state: state, actions: sceneActions),
                    dark: dark,
                    name: "spaces-suggestions-\(dark ? "dark" : "light")"
                )
            }
            state.browser.page = "spaceSpam"; state.browser.scope = .spamInvitations
            state.browser.spaces = []
            try await render(
                ConversationDirectoryView(state: state, actions: sceneActions),
                dark: false,
                name: "spaces-spam"
            )
        }

        private func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }

        private func render(
            _ view: some View,
            dark: Bool,
            name: String,
            size: NSSize = NSSize(width: 760, height: 460)
        ) async throws {
            let host = NSHostingView(rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.size == size)
            let scrolls = scrollViews(in: host)
            #expect(
                scrolls.contains { $0.frame.width >= 200 && $0.frame.height >= 100 },
                "The native scrolling body must receive a usable viewport."
            )
            if let path = ProcessInfo.processInfo.environment["KIBBLE_RENDER_CAPTURE_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(name).png"))
            }
        }
    }
#endif
