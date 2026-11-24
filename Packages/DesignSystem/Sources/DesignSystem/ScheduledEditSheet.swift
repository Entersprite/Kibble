import ChatKit
import SwiftUI

/// Edit Message…, a sheet over the Scheduled pane: the message's words in
/// the composer's own field, so mentions and formatting survive the edit.
/// Save takes Return, in the field and on the button; Cancel takes Escape.
struct ScheduledEditSheet: View {
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
            HStack {
                Text("Edit Scheduled Message")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving message")
                }
            }
            Label(
                "Sends \(ScheduledPresentation.time(item.deliveryTime))", systemImage: "clock"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if item.isForward == true {
                Label("Forwarded message", systemImage: "arrowshape.turn.up.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            field
                .disabled(isSaving)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            if failed {
                SheetErrorRow(message: "The edit " + ScheduledPresentation.unconfirmedText)
                    .font(.callout)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: submit)
                    .disabled(!canSave)
            }
        }
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
        let started = save(draft.composed(formatting: formatting)) { accepted in
            isSaving = false
            if accepted {
                dismiss()
            } else {
                failed = true
            }
        }
        if !started {
            isSaving = false
            failed = true
        }
    }
}
