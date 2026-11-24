import ChatKit
import SwiftUI

/// What the Scheduled pane says apart from its rows.
enum ScheduledPresentation {
    static let loadingText = "Loading scheduled messages…"
    static let failedTitle = "Couldn’t Load Scheduled Messages"
    static let moreFailedText = "Couldn’t load more scheduled messages."
    static let unconfirmedText = "couldn’t be confirmed. Check Scheduled before trying again."

    /// When it goes out, as a row and a sheet say it.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// A message with no words is still a row: its files or its forward say what it is.
    static func body(of message: ScheduledMessage) -> String? {
        if !message.body.text.isEmpty {
            return message.body.text
        }
        return message.hasContentWithoutCaption ? nil : "Message"
    }
}

/// The Scheduled list, in the detail pane: messages waiting to go out,
/// soonest as the service orders them. A `List`, as the Mentions and Calls
/// lists are: a click selects a row, Return or a double-click edits it (or
/// moves it, where its words cannot be edited), and the context menu and the
/// row's own menu offer the rest. Reaching the last row asks for the next page.
struct ScheduledMessagesPane: View {
    let state: ChatSceneState
    let actions: ScheduledMessagesActions
    @State private var selection: ScheduledMessageAddress?
    @State private var editing: ScheduledMessage?
    @State private var moving: ScheduledMessage?
    @State private var moveFailed = false
    @State private var deletion: ScheduledMessageAddress?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(state.scheduled.messages) { message in
                    row(message)
                        .tag(message.id)
                        .onAppear {
                            if message.id == state.scheduled.messages.last?.id, canLoadMore {
                                actions.loadMore()
                            }
                        }
                }
            } footer: {
                footer
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ScheduledMessageAddress.self) { ids in
            if let message = PaneSelection.single(ids, in: state.scheduled.messages) {
                menuItems(for: message)
            }
        } primaryAction: { ids in
            if let message = PaneSelection.single(ids, in: state.scheduled.messages),
               !state.scheduled.pending.contains(message.id) {
                if message.canEditBody {
                    editing = message
                } else {
                    move(message)
                }
            }
        }
        .overlay {
            if state.scheduled.messages.isEmpty {
                emptyState
            }
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise", action: actions.refresh)
                .disabled(busy)
                .help("Refresh Scheduled Messages")
        }
        .sheet(item: $editing) { item in
            ScheduledEditSheet(
                item: item, formatting: state.capabilities.canFormatMessages,
                save: { actions.edit(item.id, $0, $1) }
            )
        }
        .sheet(item: $moving) { item in
            ScheduledDateSheet(
                title: "Reschedule Message", confirm: "Reschedule",
                initial: max(item.deliveryTime, Date().addingTimeInterval(60)),
                cancel: { moving = nil },
                save: { date in reschedule(item, to: date) },
                isSaving: state.scheduled.pending.contains(item.id), failed: moveFailed
            )
        }
        .alert(
            "Delete This Scheduled Message?",
            isPresented: Binding(get: { deletion != nil }, set: { shown in
                if !shown {
                    deletion = nil
                }
            }),
            presenting: deletion
        ) { address in
            Button("Delete", role: .destructive) { actions.cancel(address) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It won’t be sent.")
        }
    }

    private var busy: Bool {
        state.scheduled.isLoading || !state.scheduled.pending.isEmpty
    }

    private var canLoadMore: Bool {
        state.scheduled.hasMore && !busy && !state.scheduled.readFailed
    }

    private func move(_ message: ScheduledMessage) {
        moveFailed = false
        moving = message
    }

    private func reschedule(_ item: ScheduledMessage, to date: Date) {
        moveFailed = false
        let started = actions.reschedule(item.id, date) { accepted in
            guard moving?.id == item.id else { return }
            if accepted {
                moving = nil
            } else {
                moveFailed = true
            }
        }
        if !started {
            moveFailed = true
        }
    }

    /// Below the rows: the next page on its way, or a read that failed.
    @ViewBuilder private var footer: some View {
        if !state.scheduled.messages.isEmpty {
            HStack(spacing: 8) {
                if state.scheduled.isLoading {
                    ProgressView().controlSize(.small)
                } else if state.scheduled.readFailed {
                    Text(ScheduledPresentation.moreFailedText)
                    Button(
                        "Try Again",
                        action: state.scheduled.hasMore ? actions.loadMore : actions.refresh
                    )
                    .controlSize(.small)
                } else if state.scheduled.hasMore {
                    Button("Load More", action: actions.loadMore)
                        .controlSize(.small)
                        .disabled(busy)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if state.scheduled.isLoading {
            ProgressView(ScheduledPresentation.loadingText)
        } else if state.scheduled.readFailed {
            ContentUnavailableView {
                Label(ScheduledPresentation.failedTitle, systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try Again", action: actions.refresh)
            }
        } else {
            ContentUnavailableView(
                "No Scheduled Messages", systemImage: "clock",
                description: Text("Messages you schedule wait here until they’re sent.")
            )
        }
    }

    @ViewBuilder private func menuItems(for message: ScheduledMessage) -> some View {
        if message.canEditBody {
            Button("Edit Message…", systemImage: "pencil") { editing = message }
        }
        Button("Reschedule…", systemImage: "clock") { move(message) }
        if let sendNow = actions.sendNow {
            Button("Send Now", systemImage: "paperplane") { sendNow(message.id) }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { deletion = message.id }
    }

    /// Where it goes and when on one line, then what it says. A send that
    /// failed says so in red, as a failed message does in the transcript.
    private func row(_ message: ScheduledMessage) -> some View {
        let pending = state.scheduled.pending.contains(message.id)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(conversationTitle(message))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Label(ScheduledPresentation.time(message.deliveryTime), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let body = ScheduledPresentation.body(of: message) {
                    Text(body).lineLimit(3)
                }
                if message.isForward == true {
                    Label("Forwarded message", systemImage: "arrowshape.turn.up.right")
                        .foregroundStyle(.secondary)
                }
                if let names = message.attachmentNames, !names.isEmpty {
                    Label(ListFormatter.localizedString(byJoining: names), systemImage: "paperclip")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if message.deliveryFailed {
                    Label("Couldn’t send", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .accessibilityElement(children: .combine)
            if pending {
                ProgressView().controlSize(.small).accessibilityLabel("Updating scheduled message")
            } else {
                Menu {
                    menuItems(for: message)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Actions for This Scheduled Message")
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func conversationTitle(_ message: ScheduledMessage) -> String {
        guard let conversation = state.conversations.first(where: { $0.id == message.id.conversation }) else {
            return "Conversation"
        }
        return Display.title(of: conversation, directory: state.directory, me: state.me)
    }
}
