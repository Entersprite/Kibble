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

/// What the Starred pane says apart from its rows.
enum StarredPresentation {
    static let openTitle = MentionsPresentation.openTitle
    static let loadingText = "Loading starred messages…"
    static let failedTitle = "Couldn’t Load Starred Messages"
    static let moreFailedText = "Couldn’t load more starred messages."

    /// A message with no words is named by its first file.
    static func preview(of message: Message) -> String {
        message.text.isEmpty ? message.attachments.first?.name ?? "Message" : message.text
    }
}

/// The Starred list, in the detail pane: a `List`, as the Mentions and Calls
/// lists are. A click selects a row, Return or a double-click shows the
/// message in its conversation, and the star at the row's end takes the
/// star off. Reaching the last row asks for the next page.
struct StarredMessagesPane: View {
    let state: ChatSceneState
    let actions: StarredMessagesActions
    let open: ((MessageAddress) -> Void)?
    @State private var selection: MessageAddress?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(state.stars.messages, id: \.starredAddress) { message in
                    row(message)
                        .tag(MessageAddress(message))
                        .onAppear {
                            if message.id == state.stars.messages.last?.id, canLoadMore {
                                actions.loadMore()
                            }
                        }
                }
            } footer: {
                footer
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
                    Button(StarredPresentation.openTitle, systemImage: "text.bubble") { open?(address) }
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
            Button("Refresh", systemImage: "arrow.clockwise", action: actions.refresh)
                .disabled(isBusy)
                .help("Refresh Starred Messages")
        }
    }

    private var isBusy: Bool {
        state.stars.isLoading || !state.stars.pending.isEmpty
    }

    private var canLoadMore: Bool {
        state.stars.hasMore && !isBusy && !state.stars.readFailed
    }

    /// Below the rows: the next page on its way, or one that failed and can
    /// be asked for again. An empty first page with more behind it says so
    /// here too, since there is no row to reach.
    @ViewBuilder private var footer: some View {
        if !state.stars.messages.isEmpty || state.stars.hasMore {
            HStack(spacing: 8) {
                if state.stars.isLoading {
                    ProgressView().controlSize(.small)
                } else if state.stars.readFailed {
                    Text(StarredPresentation.moreFailedText)
                    Button("Try Again", action: state.stars.hasMore ? actions.loadMore : actions.refresh)
                        .controlSize(.small)
                } else if state.stars.hasMore {
                    Button("Load More", action: actions.loadMore)
                        .controlSize(.small)
                        .disabled(isBusy)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if state.stars.isLoading {
            ProgressView(StarredPresentation.loadingText)
        } else if state.stars.readFailed {
            ContentUnavailableView {
                Label(StarredPresentation.failedTitle, systemImage: "exclamationmark.triangle")
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

    /// The Mentions row's shape: where and who on one line with the time at
    /// its end, then the message. The star takes it back off the list.
    private func row(_ message: Message) -> some View {
        let sender = state.stars.members[message.sender] ?? state.directory[message.sender]
        let conversation = state.conversations.first { $0.id == message.conversationID }
        let address = MessageAddress(message)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(conversation
                        .map { Display.title(of: $0, directory: state.directory, me: state.me) }
                        ?? "Conversation")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(sender?.displayName ?? "Unknown sender")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Display.timestamp(of: message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(StarredPresentation.preview(of: message))
                    .lineLimit(3)
            }
            .accessibilityElement(children: .combine)
            Button { actions.set(false, address) } label: {
                Label("Unstar", systemImage: "star.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.borderless)
            .disabled(state.stars.pending.contains(address))
            .help("Unstar")
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
