import ChatKit
import SwiftUI

public struct ScheduledMessagesScene: Sendable, Equatable {
    public var showingList = false
    public var canScheduleAttachments = false
    public var messages: [ScheduledMessage] = []
    public var pending: Set<ScheduledMessageAddress> = []
    public var submissions: Set<ComposerDraftAddress> = []
    public var receipts: [ComposerDraftAddress: ComposerScheduleReceipt] = [:]
    public var isLoading = false
    public var readFailed = false
    public var hasMore = false

    public init() {}
}

@MainActor
public struct ScheduledMessagesActions {
    public typealias Completion = @MainActor (Bool) -> Void
    public var show: () -> Void
    public var refresh: () -> Void
    public var loadMore: () -> Void
    let submit: (ComposerDraftAddress, ComposedMessage, ComposedMessage, Date) -> Bool
    let latestReceipt: (ComposerDraftAddress) -> ComposerScheduleReceipt?
    let edit: (ScheduledMessageAddress, ComposedMessage, @escaping Completion) -> Bool
    let reschedule: (ScheduledMessageAddress, Date, @escaping Completion) -> Bool
    let cancel: (ScheduledMessageAddress) -> Void
    let sendNow: ((ScheduledMessageAddress) -> Void)?

    public init(
        show: @escaping () -> Void,
        refresh: @escaping () -> Void,
        loadMore: @escaping () -> Void,
        submit: @escaping (ComposerDraftAddress, ComposedMessage, ComposedMessage, Date) -> Bool,
        latestReceipt: @escaping (ComposerDraftAddress) -> ComposerScheduleReceipt?,
        edit: @escaping (ScheduledMessageAddress, ComposedMessage, @escaping Completion) -> Bool,
        reschedule: @escaping (ScheduledMessageAddress, Date, @escaping Completion) -> Bool,
        cancel: @escaping (ScheduledMessageAddress) -> Void,
        sendNow: ((ScheduledMessageAddress) -> Void)? = nil
    ) {
        self.show = show
        self.refresh = refresh
        self.loadMore = loadMore
        self.submit = submit
        self.latestReceipt = latestReceipt
        self.edit = edit
        self.reschedule = reschedule
        self.cancel = cancel
        self.sendNow = sendNow
    }

    func composer(at address: ComposerDraftAddress, scene: ScheduledMessagesScene) -> ComposerScheduling {
        ComposerScheduling(
            isSubmitting: scene.submissions.contains(address),
            receipt: scene.receipts[address],
            latestReceipt: { latestReceipt(address) },
            schedule: { submit(address, $0, $1, $2) },
            canScheduleAttachments: scene.canScheduleAttachments
        )
    }
}

struct ScheduledMessagesPane: View {
    let state: ChatSceneState
    let actions: ScheduledMessagesActions
    @State private var editing: ScheduledMessage?
    @State private var moving: ScheduledMessage?
    @State private var moveFailed = false
    @State private var deletion: ScheduledMessageAddress?

    var body: some View {
        List {
            ForEach(state.scheduled.messages) { message in
                row(message)
            }
            if !state.scheduled.messages.isEmpty, state.scheduled.readFailed {
                Text("Couldn’t load scheduled messages").foregroundStyle(.secondary)
            }
            if !state.scheduled.messages.isEmpty, state.scheduled.hasMore {
                Button("Load More", action: actions.loadMore).disabled(busy)
            }
        }
        .listStyle(.inset)
        .overlay {
            if state.scheduled.messages.isEmpty {
                emptyState
            }
        }
        .toolbar {
            Button("Refresh Scheduled", systemImage: "arrow.clockwise", action: actions.refresh)
                .disabled(busy)
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
                save: { date in
                    moveFailed = false
                    if !actions.reschedule(item.id, date, { accepted in
                        guard moving?.id == item.id else { return }
                        if accepted {
                            moving = nil
                        } else {
                            moveFailed = true
                        }
                    }) {
                        moveFailed = true
                    }
                },
                isSaving: state.scheduled.pending.contains(item.id), failed: moveFailed
            )
        }
        .alert(
            "Cancel This Scheduled Message?",
            isPresented: Binding(get: { deletion != nil }, set: {
                if !$0 {
                    deletion = nil
                }
            }),
            presenting: deletion
        ) { address in
            Button("Cancel Scheduled Send", role: .destructive) { actions.cancel(address) }
            Button("Keep Message", role: .cancel) {}
        }
    }

    private var busy: Bool {
        state.scheduled.isLoading || !state.scheduled.pending.isEmpty
    }

    @ViewBuilder private var emptyState: some View {
        if state.scheduled.isLoading {
            ProgressView("Loading scheduled messages")
        } else if state.scheduled.readFailed {
            ContentUnavailableView {
                Label("Couldn’t Load Scheduled Messages", systemImage: "clock")
            } actions: {
                Button("Try Again", action: actions.refresh)
            }
        } else {
            ContentUnavailableView("No Scheduled Messages", systemImage: "clock")
        }
    }

    private func row(_ message: ScheduledMessage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversationTitle(message)).font(.callout.weight(.semibold)).lineLimit(1)
                if !message.body.text.isEmpty || !message.hasContentWithoutCaption {
                    Text(message.body.text.isEmpty ? "Message" : message.body.text).lineLimit(3)
                }
                if message.isForward == true {
                    Label("Forwarded a message", systemImage: "arrowshape.turn.up.right")
                        .foregroundStyle(.secondary)
                }
                if let names = message.attachmentNames, !names.isEmpty {
                    Label(ListFormatter.localizedString(byJoining: names), systemImage: "paperclip")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if message.deliveryFailed {
                    Label("Couldn’t send", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
                Text(message.deliveryTime, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                if message.canEditBody {
                    Button("Edit Message…", systemImage: "pencil") { editing = message }
                }
                Button("Reschedule…", systemImage: "clock") {
                    moveFailed = false
                    moving = message
                }
                if let sendNow = actions.sendNow {
                    Button("Send Now", systemImage: "paperplane") { sendNow(message.id) }
                }
                Button("Cancel Scheduled Send…", systemImage: "trash", role: .destructive) {
                    deletion = message.id
                }
            } label: {
                Label("Scheduled Message Actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(state.scheduled.pending.contains(message.id))
        }
        .padding(.vertical, 4)
    }

    private func conversationTitle(_ message: ScheduledMessage) -> String {
        guard let conversation = state.conversations.first(where: { $0.id == message.id.conversation }) else {
            return "Conversation"
        }
        return Display.title(of: conversation, directory: state.directory, me: state.me)
    }
}

private struct ScheduledEditSheet: View {
    let formatting: Bool
    let item: ScheduledMessage
    let save: (ComposedMessage, @escaping ScheduledMessagesActions.Completion) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ComposerDraft()
    @State private var isSaving = false
    @State private var failed = false
    @State private var focusRequest = 0

    init(
        item: ScheduledMessage, formatting: Bool,
        save: @escaping (ComposedMessage, @escaping ScheduledMessagesActions.Completion) -> Bool
    ) {
        self.formatting = formatting
        self.save = save
        self.item = item
        var draft = ComposerDraft()
        draft.adopt(item.body, formatting: formatting)
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Scheduled Message").font(.headline)
            if item.isForward == true {
                Label("Forwarded a message", systemImage: "arrowshape.turn.up.right")
                    .foregroundStyle(.secondary)
            }
            field
                .disabled(isSaving)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            if failed {
                Text("The edit could not be confirmed. Check the queue before trying again.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .interactiveDismissDisabled(isSaving)
        .onAppear { focusRequest += 1 }
    }

    private var field: some View {
        #if os(macOS)
            ComposerTextView(
                draft: $draft, anchorX: .constant(0), placeholder: "Scheduled message",
                listOpen: false, focusRequest: focusRequest, onKey: { _ in }, onSubmit: submit,
                formatting: formatting
            )
            .frame(minHeight: 56)
        #else
            TextEditor(text: Binding(get: { draft.text }, set: { draft.edit($0) })).frame(minHeight: 72)
        #endif
    }

    private var canSave: Bool {
        !isSaving && (item.hasContentWithoutCaption ||
            !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func submit() {
        guard canSave else { return }
        failed = false
        isSaving = true
        if !save(draft.composed(formatting: formatting), { accepted in
            isSaving = false
            if accepted {
                dismiss()
            } else {
                failed = true
            }
        }) {
            isSaving = false
            failed = true
        }
    }
}
