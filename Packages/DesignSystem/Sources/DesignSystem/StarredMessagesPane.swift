import ChatKit
import SwiftUI

public struct StarredMessagesScene: Sendable, Equatable {
    public var showingList = false
    public var messages: [Message] = []
    public var members: [Member.ID: Member] = [:]
    public var knownStars: Set<MessageAddress> = []
    public var pending: Set<MessageAddress> = []
    public var isLoading = false
    public var readFailed = false
    public var hasMore = false

    public init() {}
}

@MainActor
public struct StarredMessagesActions {
    public var show: () -> Void
    public var refresh: () -> Void
    public var loadMore: () -> Void
    public var set: (Bool, MessageAddress) -> Void

    public init(
        show: @escaping () -> Void, refresh: @escaping () -> Void, loadMore: @escaping () -> Void,
        set: @escaping (Bool, MessageAddress) -> Void
    ) {
        self.show = show
        self.refresh = refresh
        self.loadMore = loadMore
        self.set = set
    }
}

struct StarredMessagesPane: View {
    let state: ChatSceneState
    let actions: StarredMessagesActions
    let open: ((MessageAddress) -> Void)?
    @State private var selection: MessageAddress?

    var body: some View {
        List(selection: $selection) {
            ForEach(state.stars.messages, id: \.starredAddress) { message in
                row(message).tag(MessageAddress(message))
            }
            if !state.stars.messages.isEmpty || state.stars.hasMore {
                if state.stars.readFailed {
                    Text("Couldn’t load starred messages").foregroundStyle(.secondary)
                }
                if state.stars.hasMore {
                    Button("Load More", action: actions.loadMore)
                        .disabled(state.stars.isLoading || !state.stars.pending.isEmpty)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if state.stars.messages.isEmpty, !state.stars.hasMore {
                emptyState
            }
        }
        .contextMenu(forSelectionType: MessageAddress.self) { addresses in
            if addresses.count == 1, let address = addresses.first {
                if canOpen(address) {
                    Button("Open Message") { open?(address) }
                }
                Button("Unstar", systemImage: "star.slash") { actions.set(false, address) }
                    .disabled(state.stars.pending.contains(address))
            }
        } primaryAction: { addresses in
            if addresses.count == 1, let address = addresses.first, canOpen(address) {
                open?(address)
            }
        }
        .toolbar {
            Button("Refresh Starred", systemImage: "arrow.clockwise", action: actions.refresh)
                .disabled(state.stars.isLoading || !state.stars.pending.isEmpty)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if state.stars.isLoading {
            ProgressView("Loading starred messages")
        } else if state.stars.readFailed {
            ContentUnavailableView {
                Label("Couldn’t Load Starred Messages", systemImage: "star")
            } actions: {
                Button("Try Again", action: actions.refresh)
            }
        } else {
            ContentUnavailableView(
                "No Starred Messages", systemImage: "star",
                description: Text("Star a message to find it here later.")
            )
        }
    }

    private func row(_ message: Message) -> some View {
        let sender = state.stars.members[message.sender] ?? state.directory[message.sender]
        let conversation = state.conversations.first { $0.id == message.conversationID }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation
                    .map { Display.title(of: $0, directory: state.directory, me: state.me) } ??
                    "Conversation")
                    .font(.callout.weight(.semibold))
                Text(sender?.displayName ?? "Unknown sender")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(message.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Text(message.text.isEmpty ? message.attachments.first?.name ?? "Message" : message.text)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func canOpen(_ address: MessageAddress) -> Bool {
        open != nil && state.conversations.contains { $0.id == address.conversation }
    }
}

private extension Message {
    var starredAddress: MessageAddress {
        MessageAddress(self)
    }
}
