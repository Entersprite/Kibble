import ChatKit
import SwiftUI

/// A full list behind a sidebar section's See All: People, Group Chats,
/// Apps, Meet Chats, or the Spaces browser.
///
/// Laid out like Mail and Photos: the list fills the column and scrolls
/// under the toolbar, and the page's controls are toolbar items, in Liquid
/// Glass: the system search field at the trailing edge, Sort, and the way
/// to start a new conversation. The window shows this view only while a
/// page is open, so its search field and items leave with it.
///
/// Native lists: a click selects, a double-click or Return opens, and the
/// context menu says what opening does.
struct ConversationDirectoryView: View {
    let state: ChatSceneState
    let actions: ChatSceneActions
    @State private var selectedPerson: Member.ID?
    @State private var selectedConversation: Conversation.ID?

    private var page: String? {
        browser.page ?? browser.lastPage
    }

    private var browser: ConversationBrowserScene {
        state.browser
    }

    private var isSpacePage: Bool {
        page == "space" || page == "spaceSpam"
    }

    private var isPeoplePage: Bool {
        page == "people" || page == "directMessage"
    }

    /// The sidebar section whose sort this page shares.
    private var sectionID: String {
        isSpacePage ? "space" : isPeoplePage ? "directMessage" : page ?? "directMessage"
    }

    var body: some View {
        Group {
            if isSpacePage {
                SpacesDirectoryContent(state: state, actions: actions)
            } else if isPeoplePage {
                peopleList
            } else {
                conversationList
            }
        }
        .searchable(
            text: Binding(get: { browser.query }, set: { actions.browser?.search($0, nil, false) }),
            placement: .toolbar,
            prompt: Text(searchPrompt)
        )
        .toolbar { toolbarItems }
    }

    // MARK: Toolbar

    private var searchPrompt: String {
        switch page {
        case "space": "Search Spaces"
        case "spaceSpam": "Search Invitations"
        case "groupDirectMessage": "Search Group Chats"
        case "appDirectMessage": "Search Apps"
        case "meetChat": "Search Meet Chats"
        default: "Search People"
        }
    }

    /// Sort and New, each in a glass capsule of its own, before the search
    /// field the system places at the trailing edge.
    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if page != "spaceSpam", let update = actions.updateSidebar {
            ToolbarItem(id: "directory.sort", placement: .primaryAction) {
                Menu {
                    SidebarSortMenuItems(section: state.sidebarPreferences.section(sectionID)) {
                        update(state.sidebarPreferences.updating($0))
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuIndicator(.hidden)
                .help("Sort")
            }
        }
        if let creation {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(id: "directory.create", placement: .primaryAction) {
                Button(creation.title, systemImage: creation.icon) {
                    actions.browser?.beginCreation(creation.kind)
                }
                .help(creation.title)
            }
        }
    }

    private struct Creation {
        var title: String
        var icon: String
        var kind: Conversation.Kind
    }

    private var creation: Creation? {
        let capabilities = state.capabilities
        if page == "space", capabilities.canCreateConversations {
            return Creation(title: "New Space", icon: "plus", kind: .space)
        }
        if page == "groupDirectMessage", capabilities.canCreateConversations {
            return Creation(title: "New Group Chat", icon: "plus", kind: .groupDirectMessage)
        }
        if isPeoplePage, capabilities.canOpenDirectConversations {
            return Creation(title: "New Message", icon: "square.and.pencil", kind: .directMessage)
        }
        return nil
    }

    // MARK: People

    private var people: [Member] {
        PeopleDirectoryProjection.build(state)
    }

    private var canMessage: Bool {
        state.capabilities.canOpenDirectConversations
    }

    /// Opens the DM straight away, with no sheet sliding in and out on the
    /// way. Only a failure shows one, to say what went wrong.
    private func message(_ id: Member.ID) {
        guard canMessage else { return }
        actions.browser?.create(ConversationDraft(kind: .directMessage, members: [id]))
    }

    private var peopleList: some View {
        List(selection: $selectedPerson) {
            if !people.isEmpty {
                DirectorySectionHeader(title: DirectorySectionHeader.count(
                    people.count, browser.query.isEmpty ? ("Person", "People") : ("Result", "Results")
                ))
            }
            ForEach(people, id: \.id) { person in
                DirectoryRow(isSelected: selectedPerson == person.id) { revealed in
                    PersonRow(person: person, size: DirectoryLayout.pictureSize) {
                        if canMessage {
                            Button("Send Message", systemImage: "bubble.left.fill") { message(person.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .help("Send Message")
                                .opacity(revealed ? 1 : 0)
                        }
                    }
                }
                .tag(person.id)
            }
            status
            if browser.query.isEmpty, !people.isEmpty {
                Text("Search by name or email to find anyone in your directory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: Member.ID.self) { ids in
            if ids.count == 1, let id = ids.first, canMessage {
                Button("Send Message") { message(id) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first {
                message(id)
            }
        }
        .overlay {
            if people.isEmpty, !browser.isLoading, browser.error == nil {
                if browser.query.isEmpty {
                    ContentUnavailableView(
                        "No People Yet",
                        systemImage: "person.2",
                        description: Text("Search by name or email to find someone.")
                    )
                } else {
                    ContentUnavailableView.search(text: browser.query)
                }
            }
        }
    }

    // MARK: Group chats, apps and Meet chats

    private var localConversations: [Conversation] {
        let preferences = SidebarPreferences(sections: state.sidebarPreferences.orderedSections.map {
            var section = $0
            section.isVisible = true
            return section
        })
        return SidebarProjection.build(
            state.conversations,
            preferences: preferences,
            directory: state.directory,
            me: state.me,
            limited: false
        )
        .first { $0.id == page }?.conversations.filter {
            browser.query.isEmpty || Display.title(of: $0, directory: state.directory, me: state.me)
                .localizedCaseInsensitiveContains(browser.query)
        } ?? []
    }

    private var conversationList: some View {
        List(selection: $selectedConversation) {
            if !localConversations.isEmpty {
                DirectorySectionHeader(title: DirectorySectionHeader.count(
                    localConversations.count, browser.query.isEmpty ? noun : ("Result", "Results")
                ))
            }
            ForEach(localConversations, id: \.id) { conversation in
                DirectoryConversationRow(conversation: conversation, state: state)
                    .tag(conversation.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: Conversation.ID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Open") { actions.select(id) }
                if state.capabilities.canReadConversationDetails, let browser = actions.browser {
                    Button("Show Details…") { browser.details(id, false) }
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first {
                actions.select(id)
            }
        }
        .overlay {
            if localConversations.isEmpty {
                if browser.query.isEmpty {
                    emptyConversations
                } else {
                    ContentUnavailableView.search(text: browser.query)
                }
            }
        }
    }

    private var noun: (String, String) {
        switch page {
        case "groupDirectMessage": ("Group Chat", "Group Chats")
        case "appDirectMessage": ("App", "Apps")
        default: ("Meet Chat", "Meet Chats")
        }
    }

    @ViewBuilder private var emptyConversations: some View {
        switch page {
        case "groupDirectMessage":
            ContentUnavailableView(
                "No Group Chats",
                systemImage: "person.3",
                description: Text("Start a group chat to bring people together.")
            )
        case "appDirectMessage":
            ContentUnavailableView(
                "No Apps",
                systemImage: "app",
                description: Text("Conversations with apps appear here.")
            )
        default:
            ContentUnavailableView(
                "No Meet Chats",
                systemImage: "video",
                description: Text("Chats from meetings appear here.")
            )
        }
    }

    @ViewBuilder private var status: some View {
        if let error = browser.error {
            DirectoryErrorRow(message: error) { actions.browser?.search(browser.query, nil, false) }
        } else if browser.isLoading {
            DirectoryLoadingRow()
        }
    }
}

/// The sidebar's + button: every way to start a conversation this backend
/// offers. Each item opens a sheet that asks for more, hence the ellipses.
struct ConversationSidebarTools: ToolbarContent {
    let capabilities: Capabilities
    let actions: ConversationBrowserActions

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(id: "sidebar.create", placement: .primaryAction) {
            Menu {
                if capabilities.canOpenDirectConversations {
                    Button("New Message…", systemImage: "square.and.pencil") {
                        actions.beginCreation(.directMessage)
                    }
                }
                if capabilities.canCreateConversations {
                    Button("New Group Chat…", systemImage: "person.3") {
                        actions.beginCreation(.groupDirectMessage)
                    }
                    Button("New Space…", systemImage: "number") { actions.beginCreation(.space) }
                }
            } label: {
                Label("New Conversation", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .help("New Conversation")
        }
    }
}
