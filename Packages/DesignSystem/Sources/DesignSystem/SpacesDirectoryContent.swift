import ChatKit
import SwiftUI

struct SpacesDirectoryContent: View {
    let state: ChatSceneState
    let actions: ChatSceneActions
    private var browser: ConversationBrowserScene {
        state.browser
    }

    private var spam: Bool {
        browser.page == "spaceSpam"
    }

    var body: some View {
        VStack(spacing: 0) {
            filters.padding([.horizontal, .bottom])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !suggestions.isEmpty {
                        Text("Spaces that might interest you").font(.headline).padding(.bottom, 12)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], spacing: 12) {
                            ForEach(suggestions, id: \.conversation.id) { detail in card(detail) }
                        }.padding(.bottom, 24)
                        Text("You might also like").font(.headline).padding(.bottom, 8)
                    }
                    ForEach(rows, id: \.conversation.id) { detail in
                        row(detail)
                        Divider()
                    }
                    if browser.hasMore {
                        Button("Load More") { actions.browser?.search(browser.query, nil, true) }
                            .disabled(browser.isLoading).padding(.vertical)
                    }
                }.padding(.horizontal).padding(.bottom)
            }
            .overlay {
                if !browser.isLoading, browser.error == nil, visible.isEmpty {
                    ContentUnavailableView(
                        spam ? "No Spam Invites" : "No Matching Spaces",
                        systemImage: spam ? "envelope.badge.shield.half.filled" : "number",
                        description: Text(spam ? "Invitations marked as spam will appear here." :
                            "Try a different space name or change the filters.")
                    )
                }
            }
        }
    }

    @ViewBuilder private var filters: some View {
        if spam {
            HStack {
                Button("Browse spaces", systemImage: "chevron.left") { actions.browser?.show("space") }
                Spacer()
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { membership; organization; Spacer(); spamButton }
                VStack(alignment: .leading, spacing: 8) {
                    membership
                    HStack { organization; Spacer(); spamButton }
                }
            }
        }
    }

    private var membership: some View {
        Picker("Membership", selection: Binding(
            get: { browser.scope.type },
            set: { actions.browser?.search(browser.query, SpaceDirectoryScope($0), false) }
        )) {
            Text("All spaces").tag(SpaceDirectoryScope.all.type)
            Text("Spaces I have joined").tag(SpaceDirectoryScope.joined.type)
            Text("Spaces I haven't joined").tag(SpaceDirectoryScope.discover.type)
        }.pickerStyle(.menu).labelsHidden().fixedSize()
    }

    private var organization: some View {
        Picker("Organization", selection: Binding(
            get: { browser.organization.type },
            set: { actions.browser?.setSpaceOrganization(SpaceDirectoryOrganization($0)) }
        )) {
            Text("Internal & external").tag(SpaceDirectoryOrganization.all.type)
            Text("Internal").tag(SpaceDirectoryOrganization.internalOnly.type)
            Text("External").tag(SpaceDirectoryOrganization.externalOnly.type)
        }.pickerStyle(.menu).labelsHidden().fixedSize()
    }

    private var spamButton: some View {
        Button("Spam invites", systemImage: "envelope.badge.shield.half.filled") {
            actions.browser?.show("spaceSpam")
        }
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
            var section = $0; section.isVisible = true; return section
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

    private func row(_ detail: ConversationDetails) -> some View {
        HStack(spacing: 12) {
            SpaceDirectoryAvatar(conversation: detail.conversation)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(detail.conversation.title ?? "Space").fontWeight(.semibold)
                    counts(detail)
                }
                HStack {
                    if let status = status(detail) {
                        Text(status).fontWeight(.medium)
                    }
                    if let description = detail.description, !description.isEmpty {
                        Text(description).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.font(.callout)
            }
            Spacer(minLength: 8)
            Button(detail.membership == .joined ? "Open" : "View") { open(detail) }
        }.padding(.vertical, 16)
    }

    private func card(_ detail: ConversationDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                SpaceDirectoryAvatar(conversation: detail.conversation)
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.conversation.title ?? "Space").fontWeight(.semibold).lineLimit(2)
                    counts(detail)
                }
            }
            if let description = detail.description, !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack { Spacer(); Button("View") { open(detail) } }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func counts(_ detail: ConversationDetails) -> some View {
        HStack(spacing: 4) {
            if let count = detail.conversation.memberCount {
                Text("\(count) \(count == 1 ? "member" : "members")")
            }
            if let count = detail.linkedGroupCount, count > 0 {
                Text("· \(count) \(count == 1 ? "group" : "groups")")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func status(_ detail: ConversationDetails) -> String? {
        switch detail.membership {
        case .joined: "Joined"
        case .invited: "Invited"
        case .requested: "Request pending"
        default: nil
        }
    }
}

private struct SpaceDirectoryAvatar: View {
    let conversation: Conversation
    var body: some View {
        Group {
            if let url = conversation.avatarURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                    placeholder: { fallback }
            } else {
                fallback
            }
        }.frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var fallback: some View {
        ZStack {
            Color.accentColor.opacity(0.15)
            Text(String((conversation.title ?? "#").prefix(1))).font(.title2).foregroundStyle(.tint)
        }
    }
}
