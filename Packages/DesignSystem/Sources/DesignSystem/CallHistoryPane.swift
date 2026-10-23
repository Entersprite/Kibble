import ChatKit
import SwiftUI

/// The Calls list, in the detail pane: the account's retained call records,
/// newest first. A `List`, as `MentionsPane` is: a click selects a row, and
/// Return or a double-click opens it in its conversation. Reaching the last
/// row asks for the next page. A record is history, so no row offers Join or
/// says a call is live; Call Back starts a new call through the same action
/// the toolbar's Call uses, only where that conversation can be called now.
public struct CallHistoryPane: View {
    let scene: CallHistoryScene
    let directory: [Member.ID: Member]
    let me: Member.ID?
    /// Conversations the call service can call now (`ChatSceneState`).
    let callable: Set<Conversation.ID>
    let actions: CallHistoryActions
    let call: ((Conversation.ID) -> Void)?
    @State private var selection: Message.ID?

    public init(
        scene: CallHistoryScene, directory: [Member.ID: Member], me: Member.ID?,
        callable: Set<Conversation.ID>, actions: CallHistoryActions, call: ((Conversation.ID) -> Void)?
    ) {
        self.scene = scene
        self.directory = directory
        self.me = me
        self.callable = callable
        self.actions = actions
        self.call = call
    }

    public var body: some View {
        // Redrawn every minute, so a row's time moves on, as the Threads
        // list's marks do. `.now`, not the timeline's date, so a redraw for
        // any other reason draws now.
        TimelineView(.everyMinute) { _ in
            let now = Date.now
            List(selection: $selection) {
                Section {
                    ForEach(scene.items) { item in
                        CallHistoryRow(
                            item: item, directory: directory, me: me, now: now, callBack: callBack(for: item)
                        )
                        .onAppear {
                            if item.id == scene.items.last?.id, scene.hasMore {
                                actions.loadMore()
                            }
                        }
                    }
                } footer: {
                    if !scene.items.isEmpty {
                        CallHistoryFooter(scene: scene, loadMore: actions.loadMore)
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: Message.ID.self) { ids in
                if let item = PaneSelection.single(ids, in: scene.items) {
                    Button(CallHistoryPresentation.openTitle, systemImage: "text.bubble") {
                        actions.open(item.conversationID, item.id)
                    }
                    if let callBack = callBack(for: item) {
                        Button(CallHistoryPresentation.callBackTitle, systemImage: "phone", action: callBack)
                    }
                }
            } primaryAction: { ids in
                if let item = PaneSelection.single(ids, in: scene.items) {
                    actions.open(item.conversationID, item.id)
                }
            }
        }
        .overlay {
            switch CallHistoryPresentation.content(scene) {
            case .loading:
                ProgressView(CallHistoryPresentation.loadingText)
            case .empty:
                ContentUnavailableView(
                    CallHistoryPresentation.emptyTitle, systemImage: CallHistoryPresentation.rowSymbol,
                    description: Text(CallHistoryPresentation.emptyText)
                )
            case .failed:
                ContentUnavailableView {
                    Label(CallHistoryPresentation.failedTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(CallHistoryPresentation.failedText)
                } actions: {
                    Button(CallHistoryPresentation.retryTitle, action: actions.retry)
                }
            case .items:
                EmptyView()
            }
        }
    }

    /// Only where the call service can call that conversation now, and only
    /// while the host offers calls at all.
    private func callBack(for item: CallHistoryItem) -> (() -> Void)? {
        guard let call, callable.contains(item.conversationID) else { return nil }
        let id = item.conversationID
        return { call(id) }
    }
}

/// Below the rows: the next page on its way, a later page that failed, and
/// what the list covers.
struct CallHistoryFooter: View {
    let scene: CallHistoryScene
    let loadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if scene.isLoadingMore {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if scene.loadMoreFailed {
                HStack(spacing: 8) {
                    Text(CallHistoryPresentation.loadMoreFailedText)
                    Button(CallHistoryPresentation.retryTitle, action: loadMore)
                        .controlSize(.small)
                }
            }
            Text(CallHistoryPresentation.coverageText)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One record: the conversation's picture and name, what happened and who
/// posted it, when, and Call Back where it can be offered. The status takes
/// the transcript card's glyph, words and red for a missed call.
struct CallHistoryRow: View {
    let item: CallHistoryItem
    let directory: [Member.ID: Member]
    let me: Member.ID?
    let now: Date
    let callBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                picture
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.conversationTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Display.timestamp(of: item.createdAt, now: now))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: CallMessageCard.symbol(of: item.status))
                            .foregroundStyle(CallMessageCard.tint(of: item.status))
                            .imageScale(.small)
                        Text(CallHistoryPresentation.statusTitle(item.status))
                            .foregroundStyle(item.status == .missed ? .red : .secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(item.senderName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.callout)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CallHistoryPresentation.spoken(item, now: now))
            // Always laid out, hidden where it cannot be offered, so every
            // row's time lines up whatever its conversation can do now.
            Button { callBack?() } label: {
                Label(CallHistoryPresentation.callBackTitle, systemImage: "phone")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .help(CallHistoryPresentation.callBackTitle)
            .opacity(callBack == nil ? 0 : 1)
            .disabled(callBack == nil)
            .accessibilityHidden(callBack == nil)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var picture: some View {
        if let conversation = item.conversation {
            ConversationPicture(conversation: conversation, directory: directory, me: me, size: 28)
        } else {
            UnknownPersonGlyph(size: 28).accessibilityHidden(true)
        }
    }
}
