import ChatKit
import SwiftUI

public struct ComposerScheduleReceipt: Equatable, Sendable {
    public let id: UUID
    public let draft: ComposedMessage

    public init(id: UUID, draft: ComposedMessage) {
        self.id = id
        self.draft = draft
    }
}

public struct ComposerScheduling {
    let isSubmitting: Bool
    let canScheduleAttachments: Bool
    let receipt: ComposerScheduleReceipt?
    let latestReceipt: () -> ComposerScheduleReceipt?
    let schedule: (ComposedMessage, ComposedMessage, Date) -> Bool

    public init(
        isSubmitting: Bool,
        receipt: ComposerScheduleReceipt?,
        latestReceipt: @escaping () -> ComposerScheduleReceipt?,
        schedule: @escaping (ComposedMessage, ComposedMessage, Date) -> Bool,
        canScheduleAttachments: Bool = false
    ) {
        self.isSubmitting = isSubmitting
        self.canScheduleAttachments = canScheduleAttachments
        self.receipt = receipt
        self.latestReceipt = latestReceipt
        self.schedule = schedule
    }
}

extension ChatSceneActions {
    func preserveDraft(at address: ComposerDraftAddress) -> ((ComposerDraft) -> Void)? {
        preserveDraft.map { persist in { persist(address, $0) } }
    }
}

extension Composer {
    var offersScheduleSend: Bool {
        guard let scheduling, draft.editing == nil, checking == nil,
              pendingInvite == nil else { return false }
        if !attachments.isEmpty {
            return scheduling.canScheduleAttachments && attachments.allSatisfy { !$0.isUploading }
        }
        return !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder var scheduleButton: some View {
        if scheduling?.isSubmitting == true {
            ProgressView().controlSize(.small).accessibilityLabel("Scheduling message")
        } else if offersScheduleSend {
            // Small and plain, as the dictation glyph beside it.
            ComposerFieldButton(title: "Schedule Send…", systemImage: "clock") {
                schedulingDate = true
            }
        }
    }

    func acceptSchedule(_ receipt: ComposerScheduleReceipt?) {
        guard let receipt, acceptedScheduleID != receipt.id else { return }
        acceptedScheduleID = receipt.id
        if draft.scheduledComposition == receipt.draft {
            draftSync?.submitted(draft.syncedComposition)
        }
        draft.clearScheduledComposition(receipt.draft)
    }

    func offerSchedule(at date: Date) {
        guard offersScheduleSend, let scheduling else { return }
        let body = draft.composed(formatting: allowsFormatting)
        if scheduling.schedule(body, draft.scheduledComposition, date) {
            schedulingDate = false
        }
    }
}

struct ScheduledDateSheet: View {
    let title: String
    let confirm: String
    let cancel: () -> Void
    let save: (Date) -> Void
    let isSaving: Bool
    let failed: Bool
    @State private var deliveryTime: Date

    init(
        title: String, confirm: String, initial: Date, cancel: @escaping () -> Void,
        save: @escaping (Date) -> Void,
        isSaving: Bool = false, failed: Bool = false
    ) {
        self.title = title
        self.confirm = confirm
        self.cancel = cancel
        self.save = save
        self.isSaving = isSaving
        self.failed = failed
        _deliveryTime = State(initialValue: initial)
    }

    /// Small enough to be a sheet or a popover, so it draws its own buttons:
    /// a popover has no toolbar to put them in. Return schedules, Escape cancels.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving")
                }
            }
            DatePicker(
                "Send on", selection: $deliveryTime, in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .disabled(isSaving)
            if failed {
                SheetErrorRow(message: "The new time " + ScheduledPresentation.unconfirmedText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if deliveryTime <= Date() {
                Text("Choose a time in the future.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(confirm) { save(deliveryTime) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || deliveryTime <= Date())
            }
        }
        .padding(20)
        .frame(width: 340)
        .interactiveDismissDisabled(isSaving)
    }
}
