import ChatKit
import SwiftUI

struct ConversationDirectoryView: View {
    let state: ChatSceneState
    let actions: ChatSceneActions
    private var page: String? {
        browser.page ?? browser.lastPage
    }

    private var browser: ConversationBrowserScene {
        state.browser
    }

    private var title: String {
        switch page {
        case "space": "Spaces"
        case "spaceSpam": "Spam invites"
        case "groupDirectMessage": "Group Chats"
        case "appDirectMessage": "Apps"
        case "meetChat": "Meet Chats"
        default: "People"
        }
    }

    private var isSpacePage: Bool {
        page == "space" || page == "spaceSpam"
    }

    private var isPeoplePage: Bool {
        page == "people" || page == "directMessage"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search \(title.lowercased())", text: Binding(
                    get: { browser.query }, set: { actions.browser?.search($0, nil, false) }
                ))
                .textFieldStyle(.roundedBorder)
                if browser.isLoading {
                    ProgressView().controlSize(.small)
                }
                if let update = actions.updateSidebar {
                    SidebarSectionMenu(
                        id: isSpacePage ? "space" : isPeoplePage ? "directMessage" : page ?? "directMessage",
                        preferences: state.sidebarPreferences,
                        update: update
                    )
                }
                creationButton
            }.padding()
            if let error = browser.error {
                Text(error).foregroundStyle(.secondary).padding()
            }
            if isSpacePage {
                SpacesDirectoryContent(state: state, actions: actions)
            } else {
                List {
                    if !isPeoplePage {
                        ForEach(localConversations, id: \.id) { conversation in
                            Button { actions.select(conversation.id) } label: {
                                ConversationRow(
                                    conversation: conversation,
                                    state: ConversationRowState(
                                        conversation: conversation,
                                        scene: state
                                    )
                                )
                            }.buttonStyle(.plain)
                        }
                    } else {
                        Section(browser.query.isEmpty ? "Known People" : "Search Results") {
                            ForEach(people, id: \.id) { person in
                                Button {
                                    actions.browser?.beginCreation(.directMessage)
                                    actions.browser?.create(ConversationDraft(
                                        kind: .directMessage,
                                        members: [person.id]
                                    ))
                                } label: { personRow(person) }
                                    .buttonStyle(.plain)
                                    .disabled(!state.capabilities.canOpenDirectConversations)
                            }
                        }
                        if browser.query.isEmpty {
                            Text("Search by name or email to find more people.").foregroundStyle(.secondary)
                        }
                    }
                    if browser.hasMore {
                        Button("Load More") { actions.browser?.search(browser.query, nil, true) }
                            .disabled(browser.isLoading)
                    }
                }
                .overlay {
                    if !browser.isLoading, browser.error == nil, let empty = emptyDirectory {
                        ContentUnavailableView(
                            empty.title,
                            systemImage: empty.icon,
                            description: Text(empty.message)
                        )
                    }
                }
            }
        }
    }

    private var emptyDirectory: EmptyConversationDirectory? {
        if page == "groupDirectMessage", localConversations.isEmpty {
            return .init(
                title: "No Group Chats",
                icon: "person.3",
                message: "Start a group chat to bring people together."
            )
        }
        if page == "appDirectMessage" || page == "meetChat", localConversations.isEmpty {
            return .init(
                title: browser.query.isEmpty ? "No \(title)" : "No Matching \(title)",
                icon: page == "appDirectMessage" ? "app" : "video",
                message: "These conversations will appear here when they sync."
            )
        }
        if isPeoplePage, people.isEmpty {
            return .init(
                title: browser.query.isEmpty ? "No People" : "No Matching People",
                icon: "person.2",
                message: "Search by name or email to find someone."
            )
        }
        return nil
    }

    private var directoryPreferences: SidebarPreferences {
        SidebarPreferences(sections: state.sidebarPreferences.orderedSections.map {
            var section = $0; section.isVisible = true; return section
        })
    }

    private var localConversations: [Conversation] {
        let kind = isPeoplePage ? "directMessage" : page
        return SidebarProjection.build(
            state.conversations,
            preferences: directoryPreferences,
            directory: state.directory,
            me: state.me,
            limited: false
        )
        .first { $0.id == kind }?.conversations.filter {
            browser.query.isEmpty || Display.title(of: $0, directory: state.directory, me: state.me)
                .localizedCaseInsensitiveContains(browser.query)
        } ?? []
    }

    private var people: [Member] {
        PeopleDirectoryProjection.build(state)
    }

    @ViewBuilder private var creationButton: some View {
        if page == "space" || page == "groupDirectMessage" {
            if state.capabilities.canCreateConversations {
                Button(page == "space" ? "New Space" : "New Group Chat", systemImage: "plus") {
                    actions.browser?.beginCreation(page == "space" ? .space : .groupDirectMessage)
                }
            }
        } else if isPeoplePage, state.capabilities.canOpenDirectConversations {
            Button("New Direct Message", systemImage: "square.and.pencil") {
                actions.browser?.beginCreation(.directMessage)
            }
        }
    }

    private func personRow(_ person: Member) -> some View {
        HStack {
            Avatar(member: person.id, directory: [person.id: person], size: 28)
            VStack(alignment: .leading) {
                Text(person.displayName ?? person.email ?? "Unknown Person")
                if let email = person.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 3)
    }
}

struct ConversationSidebarTools: ToolbarContent {
    let capabilities: Capabilities
    let actions: ConversationBrowserActions

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(id: "sidebar.create", placement: .primaryAction) {
            Menu {
                if capabilities.canOpenDirectConversations {
                    Button("New Direct Message") { actions.beginCreation(.directMessage) }
                }
                if capabilities.canCreateConversations {
                    Button("New Group Chat") { actions.beginCreation(.groupDirectMessage) }
                    Button("New Space") { actions.beginCreation(.space) }
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

private struct EmptyConversationDirectory {
    var title: String
    var icon: String
    var message: String
}
