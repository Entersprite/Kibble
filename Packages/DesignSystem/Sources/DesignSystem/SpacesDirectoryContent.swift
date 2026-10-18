import ChatKit
import SwiftUI

/// The Spaces browser's list: suggestions as cards when there is no query
/// (the service's first three), then every other space as a row. A joined
/// space opens; any other opens its preview, where it can be joined.
struct SpacesDirectoryContent: View {
    let state: ChatSceneState
    let actions: ChatSceneActions
    @State private var selection: Conversation.ID?

    private var browser: ConversationBrowserScene {
        state.browser
    }

    private var spam: Bool {
        browser.page == "spaceSpam"
    }

    var body: some View {
        List(selection: $selection) {
            if !suggestions.isEmpty {
                DirectorySectionHeader(title: "Suggested for You")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(suggestions, id: \.conversation.id) { detail in
                        SpaceCard(detail: detail) { open(detail) }
                    }
                }
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
                DirectorySectionHeader(title: "More Spaces")
            }
            ForEach(rows, id: \.conversation.id) { detail in
                SpaceRow(detail: detail) { open(detail) }
                    .tag(detail.conversation.id)
            }
            more
        }
        .listStyle(.inset)
        // The filters float over the list in glass, and the spaces scroll
        // under them.
        .safeAreaBar(edge: .top) { SpacesScopeBar(state: state, actions: actions) }
        .contextMenu(forSelectionType: Conversation.ID.self) { ids in
            if ids.count == 1, let detail = detail(ids.first) {
                Button(detail.membership == .joined ? "Open" : "Show Preview…") { open(detail) }
                if detail.membership == .joined, let update = actions.updateSidebar {
                    FavoriteMenuButton(
                        target: .conversation(detail.conversation.id), preferences: state.sidebarPreferences,
                        update: update
                    )
                }
                if detail.membership == .joined, state.capabilities.canReadConversationDetails {
                    Button("Show Details…") { actions.browser?.details(detail.conversation.id, false) }
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let detail = detail(ids.first) {
                open(detail)
            }
        }
        .overlay {
            if !browser.isLoading, browser.error == nil, visible.isEmpty {
                if spam {
                    ContentUnavailableView(
                        "No Spam Invitations",
                        systemImage: "envelope.badge.shield.half.filled",
                        description: Text("Invitations marked as spam appear here.")
                    )
                } else if !browser.query.isEmpty {
                    ContentUnavailableView.search(text: browser.query)
                } else {
                    ContentUnavailableView(
                        "No Spaces",
                        systemImage: "number",
                        description: Text("Try changing the filters.")
                    )
                }
            }
        }
    }

    /// The next page loads when the list's end comes into view, the way a
    /// long list fills itself on the Mac; a failure offers to try again.
    @ViewBuilder private var more: some View {
        if let error = browser.error {
            DirectoryErrorRow(message: error) { actions.browser?.search(browser.query, nil, !visible.isEmpty)
            }
        } else if browser.isLoading {
            DirectoryLoadingRow()
        } else if browser.hasMore {
            // A new trigger per page, so the next one appears at the new end.
            Color.clear
                .frame(height: 1)
                .id("more-\(browser.spaces.count)")
                .onAppear { actions.browser?.search(browser.query, nil, true) }
        }
    }

    private func detail(_ id: Conversation.ID?) -> ConversationDetails? {
        visible.first { $0.conversation.id == id }
    }

    private var visible: [ConversationDetails] {
        browser.spaces.filter {
            $0.conversation.kind == .space && (spam ? $0.membership == .invited :
                browser.scope == .joined ? $0.membership == .joined :
                browser.scope == .discover ? $0.membership != .joined : true)
        }
    }

    private var suggestions: [ConversationDetails] {
        !spam && browser.scope == .discover && browser.query.isEmpty && visible.count >= 5
            ? Array(visible.prefix(3)) : []
    }

    private var rows: [ConversationDetails] {
        let suggested = Set(suggestions.map(\.conversation.id))
        let remaining = visible.filter { !suggested.contains($0.conversation.id) }
        let preferences = SidebarPreferences(sections: state.sidebarPreferences.orderedSections.map {
            var section = $0
            section.isVisible = true
            return section
        })
        let ids = SidebarProjection.build(
            remaining.map(\.conversation), preferences: preferences,
            directory: state.directory, me: state.me, limited: false
        ).first { $0.id == "space" }?.conversations.map(\.id) ?? []
        let byID = Dictionary(
            remaining.map { ($0.conversation.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byID[$0] }
    }

    private func open(_ detail: ConversationDetails) {
        if detail.membership == .joined {
            actions.select(detail.conversation.id)
        } else {
            actions.browser?.preview(detail)
        }
    }
}

/// Which spaces the browser lists: two filter menus and the spam
/// invitations, as glass buttons floating over the top of the list.
struct SpacesScopeBar: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    private var browser: ConversationBrowserScene {
        state.browser
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if browser.page == "spaceSpam" {
                Button("All Spaces", systemImage: "chevron.backward") { actions.browser?.show("space") }
                    .help("Back to all spaces")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { membership; organization; Spacer(minLength: 8); spamButton }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { membership; organization }
                        spamButton
                    }
                }
            }
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var membershipTitle: String {
        switch browser.scope {
        case .all: "All Spaces"
        case .joined: "Joined"
        default: "Not Joined"
        }
    }

    private var organizationTitle: String {
        switch browser.organization {
        case .internalOnly: "Internal"
        case .externalOnly: "External"
        default: "Internal & External"
        }
    }

    private var membership: some View {
        Menu {
            Picker("Show", selection: Binding(
                get: { browser.scope.type },
                set: { actions.browser?.search(browser.query, SpaceDirectoryScope($0), false) }
            )) {
                Text("All Spaces").tag(SpaceDirectoryScope.all.type)
                Text("Spaces I’ve Joined").tag(SpaceDirectoryScope.joined.type)
                Text("Spaces I Haven’t Joined").tag(SpaceDirectoryScope.discover.type)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(membershipTitle, systemImage: "person.2")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Which spaces to show")
    }

    private var organization: some View {
        Menu {
            Picker("Organization", selection: Binding(
                get: { browser.organization.type },
                set: { actions.browser?.setSpaceOrganization(SpaceDirectoryOrganization($0)) }
            )) {
                Text("Internal & External").tag(SpaceDirectoryOrganization.all.type)
                Text("Internal Only").tag(SpaceDirectoryOrganization.internalOnly.type)
                Text("External Only").tag(SpaceDirectoryOrganization.externalOnly.type)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(organizationTitle, systemImage: "building.2")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Spaces inside or outside your organization")
    }

    private var spamButton: some View {
        Button("Spam Invitations", systemImage: "envelope.badge.shield.half.filled") {
            actions.browser?.show("spaceSpam")
        }
        .fixedSize()
    }
}

/// What the browser says about a space beyond its name: how many people
/// and groups, when the service says.
enum SpaceDirectoryText {
    static func counts(_ detail: ConversationDetails) -> String? {
        var parts: [String] = []
        if let count = detail.conversation.memberCount {
            parts.append(count == 1 ? "1 member" : "\(count) members")
        }
        if let count = detail.linkedGroupCount, count > 0 {
            parts.append(count == 1 ? "1 group" : "\(count) groups")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func action(_ detail: ConversationDetails) -> String {
        detail.membership == .joined ? "Open" : "View"
    }
}

struct SpaceRow: View {
    let detail: ConversationDetails
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ConversationPicture(conversation: detail.conversation, size: DirectoryLayout.pictureSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.conversation.title ?? "Space")
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            SpaceStatus(detail: detail)
            Button(SpaceDirectoryText.action(detail), action: open)
                .buttonStyle(.glass)
        }
        .padding(.vertical, DirectoryLayout.rowPadding)
        .padding(.horizontal, 4)
    }

    /// The counts, then the description, on one line.
    private var subtitle: String? {
        let parts = [
            SpaceDirectoryText.counts(detail),
            detail.description?.isEmpty == false ? detail.description : nil
        ]
        .compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

/// Where you stand with a space, when it is anything but a stranger.
struct SpaceStatus: View {
    let detail: ConversationDetails

    var body: some View {
        switch detail.membership {
        case .joined:
            Label("Joined", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .invited:
            Label("Invited", systemImage: "envelope.fill")
                .foregroundStyle(.tint)
        case .requested:
            Label("Requested", systemImage: "clock")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// A suggested space: a card with room for its description. Content, so it
/// sits on the window's own material rather than in glass, which the
/// guidelines keep for controls; its button is glass.
struct SpaceCard: View {
    let detail: ConversationDetails
    let open: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ConversationPicture(conversation: detail.conversation, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.conversation.title ?? "Space")
                        .font(.headline)
                        .lineLimit(2)
                    if let counts = SpaceDirectoryText.counts(detail) {
                        Text(counts).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if let description = detail.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack {
                SpaceStatus(detail: detail).font(.subheadline)
                Spacer()
                Button(SpaceDirectoryText.action(detail), action: open)
                    .buttonStyle(.glass)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.background.secondary, in: shape)
        .overlay { shape.strokeBorder(.separator.opacity(0.4)) }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .contentShape(shape)
        .onTapGesture(count: 2, perform: open)
    }
}
