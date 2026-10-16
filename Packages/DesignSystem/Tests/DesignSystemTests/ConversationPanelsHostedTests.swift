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
                    ConversationPanelOverlay(state: state, actions: sceneActions),
                    dark: dark,
                    name: "creation-\(dark ? "dark" : "light")"
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
                    ConversationPanelOverlay(state: state, actions: sceneActions),
                    dark: dark,
                    name: "management-\(dark ? "dark" : "light")"
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
                SidebarSettingsPane(preferences: .init(), update: { _ in }).frame(width: 560),
                dark: false,
                name: "sidebar-settings"
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

        private func render(_ view: some View, dark: Bool, name: String) async throws {
            let host = NSHostingView(rootView: view
                .frame(width: 760, height: 460)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 460)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.size == NSSize(width: 760, height: 460))
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
