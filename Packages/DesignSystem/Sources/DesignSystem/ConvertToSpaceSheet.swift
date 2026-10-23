import ChatKit
import SwiftUI

/// Convert “<title>” to a Space, a sheet over the Info sheet: an emoji tile
/// and a name, what the server says converting does, and the history
/// acknowledgement when it requires one. Cancel and Convert.
///
/// Convert sends at once and the sheet stays until the server answers, as
/// the webhook editor does. A confirmed conversion closes it; the Info sheet
/// shows the space only once the details read back say so. A refusal or an
/// unconfirmed answer stays here with what was typed, and the details are
/// read again before Convert is offered another time: never a blind retry.
/// If a read takes the permission away, the sheet says so and keeps Cancel.
struct ConvertToSpaceSheet: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    /// The emoji picker's source. Without it there is no Choose Emoji….
    let reactions: ReactionActions?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConversionDraft
    @State private var pickingEmoji = false
    /// Convert was sent and its answer hasn't arrived.
    @State private var sent = false
    /// The write was seen submitting.
    @State private var started = false
    /// The last answer seen, for the check a moment after sending.
    @State private var latest = Answer()
    /// Why the last Convert didn't go through. Kept here: reading the
    /// details again, to check the result, clears the browser's copy.
    @State private var failure: String?
    /// This sheet asked for the details again, and they haven't landed.
    @State private var checked = false

    init(
        details: ConversationDetails,
        state: ChatSceneState,
        actions: ConversationBrowserActions,
        reactions: ReactionActions?
    ) {
        self.details = details
        self.state = state
        self.actions = actions
        self.reactions = reactions
        _draft = State(initialValue: ConversionDraft(name: details.conversation.title ?? ""))
    }

    private var browser: ConversationBrowserScene {
        state.browser
    }

    /// The open panel's details for this conversation, as last read.
    private var current: ConversationDetails? {
        guard let current = browser.details,
              current.conversation.id == details.conversation.id else { return nil }
        return current
    }

    private var limit: Int? {
        (current ?? details).fieldLimits["name"]
    }

    /// Still a group chat, but the details no longer allow converting it.
    private var noLongerAllowed: Bool {
        guard let current else { return false }
        return current.conversation.kind == .groupDirectMessage && !ConversionDraft.allows(current)
    }

    /// `mutate` drops a write while one is on its way or the details need reloading.
    private var busy: Bool {
        browser.isSubmitting || browser.needsReconciliation || browser.isLoadingAllParticipants
    }

    private var canConvert: Bool {
        draft.isReady(
            details: current, conversion: browser.conversion, isLoadingConversion: browser.isLoadingConversion
        ) && !sent && !busy
    }

    var body: some View {
        Form {
            if noLongerAllowed {
                Section {
                    if let failure {
                        SheetErrorRow(message: failure)
                    }
                    Text("You can no longer convert this conversation.")
                }
            } else {
                identity.disabled(sent)
                consequences
                if browser.conversion?.requiresHistoryAcknowledgement == true {
                    Section {
                        Toggle(
                            "I understand conversation history settings may change.",
                            isOn: $draft.acknowledged
                        )
                        .toggleStyle(.checkbox)
                    }
                    .disabled(sent)
                }
                ConversionOutcomeSection(
                    failure: failure,
                    reconciling: checked && browser.needsReconciliation && !browser.isSubmitting && !sent,
                    readError: browser.panelError,
                    reload: check
                )
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .top) {
            SheetHeader(title: "Convert “\(title)” to a Space")
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 340, idealHeight: 400)
        .toolbar { buttons }
        .onAppear { actions.loadConversion() }
        .onChange(of: answer, initial: true) { _, now in
            latest = now
            guard sent else { return }
            if now.isSubmitting {
                started = true
            } else if started || now.error != nil {
                finish(now.error)
            }
        }
        .task(id: sent) {
            // A quick answer can arrive without the write ever showing as
            // submitting; a moment later, the latest state tells how it went.
            guard sent else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled, sent, !latest.isSubmitting {
                finish(latest.error)
            }
        }
        .onChange(of: browser.needsReconciliation) { _, reconciling in
            if !reconciling {
                checked = false
            }
        }
        .onChange(of: convertedKind) { _, kind in
            // Details read back as something else: it converted, even if the answer was uncertain.
            if let kind, kind != .groupDirectMessage {
                dismiss()
            }
        }
    }

    private var title: String {
        Display.title(of: details.conversation, directory: state.directory, me: state.me)
    }

    /// The kind the open panel's details give this conversation now.
    private var convertedKind: Conversation.Kind? {
        current?.conversation.kind
    }

    // MARK: Name and emoji

    private var identity: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                emojiTile
                VStack(alignment: .leading, spacing: 6) {
                    // Bordered: beside the tile, a plain field reads as a label.
                    TextField("Name", text: $draft.name, prompt: Text("Required"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    HStack(spacing: 8) {
                        if reactions != nil {
                            emojiButtons
                        }
                        Spacer(minLength: 8)
                        if let limit {
                            LengthCounter(length: DetailsDraft.length(draft.trimmedName), limit: limit)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var emojiTile: some View {
        if reactions != nil {
            Button { pickingEmoji = true } label: { tile }
                .buttonStyle(.plain)
                .help("Choose Emoji")
                .accessibilityLabel(draft.emoji
                    .flatMap { $0.isEmpty ? nil : "Emoji \($0)" } ?? "Default Icon")
                .popover(isPresented: $pickingEmoji, arrowEdge: .bottom) {
                    if let reactions {
                        EmojiPicker(reactions: [], actions: reactions, use: .text) { choice, _ in
                            draft.choose(choice.emoji)
                            pickingEmoji = false
                        }
                    }
                }
        } else {
            tile.accessibilityHidden(true)
        }
    }

    /// The chosen emoji, or the default picture of a space with this name.
    @ViewBuilder private var tile: some View {
        if let emoji = draft.emoji, !emoji.isEmpty {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary)
                .overlay { Text(emoji).font(.system(size: 26)) }
                .frame(width: 44, height: 44)
        } else {
            ConversationPicture(
                conversation: Conversation(
                    id: details.conversation.id,
                    kind: .space,
                    title: draft.trimmedName
                ),
                directory: state.directory, me: state.me, size: 44
            )
        }
    }

    private var emojiButtons: some View {
        HStack(spacing: 6) {
            Button("Choose Emoji…") { pickingEmoji = true }
            Button("Use Default Icon") { draft.emoji = nil }
                .disabled((draft.emoji ?? "").isEmpty)
        }
        .controlSize(.small)
    }

    // MARK: What converting does

    /// The confirmed lines, then what can't be confirmed; while they load
    /// (or load again after a failed Convert), a small progress indicator,
    /// and a failed read can be tried again.
    @ViewBuilder private var consequences: some View {
        if !browser.isLoadingConversion, let conversion = browser.conversion {
            let lines = Self.lines(conversion.items)
            let summary = ConversionText.unknownSummary(conversion.items)
            if !lines.isEmpty || summary != nil {
                Section {
                    ForEach(lines, id: \.self) { Text($0) }
                    if let summary {
                        Text(summary).foregroundStyle(.secondary)
                    }
                }
            }
        } else if !browser.isLoadingConversion, let error = browser.conversionError {
            Section {
                SheetErrorRow(message: error)
                Button("Try Again") { actions.loadConversion() }
            }
        } else {
            Section {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading what converting changes")
            }
        }
    }

    /// Each confirmed line once, in the server's order.
    private static func lines(_ items: [ConversionConsequence]) -> [String] {
        var seen = Set<String>()
        return items.compactMap(ConversionText.line).filter { seen.insert($0).inserted }
    }

    // MARK: How Convert went

    /// The model's side of a send: whether it is on its way, and any refusal.
    private struct Answer: Equatable {
        var isSubmitting = false
        var error: String?
    }

    private var answer: Answer {
        Answer(isSubmitting: browser.isSubmitting, error: browser.panelError)
    }

    private func convert() {
        failure = nil
        started = false
        sent = true
        actions.mutate(draft.mutation)
    }

    /// Closes on success. Otherwise stays with what was typed and the reason,
    /// and reads the details again when the write left them uncertain.
    private func finish(_ error: String?) {
        sent = false
        guard let error else {
            dismiss()
            return
        }
        failure = error
        if browser.needsReconciliation {
            check()
        }
    }

    /// Reads the open conversation's details and what converting does
    /// again: reads, never the write. Convert waits for both.
    private func check() {
        checked = true
        actions.details(browser.panelTarget ?? details.conversation.id, false)
        actions.loadConversion()
    }

    @ToolbarContentBuilder private var buttons: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        if sent {
            // Beside Convert, the button it is the progress of.
            ToolbarItem(placement: .confirmationAction) {
                ProgressView().controlSize(.small)
            }
        }
        if !noLongerAllowed {
            ToolbarItem(placement: .confirmationAction) {
                Button("Convert", action: convert)
                    .disabled(!canConvert)
            }
        }
    }
}

/// How this sheet's own Convert went: the refusal or unconfirmed answer,
/// then the details being read again ("Checking the result…"). If that read
/// fails, its error and Reload Details, a read and never the write. A reload
/// the sheet didn't ask for gets no words here; Convert is simply disabled.
struct ConversionOutcomeSection: View {
    let failure: String?
    /// The sheet's own read of the details is still unsettled.
    let reconciling: Bool
    /// The browser's error, set again if that read failed.
    let readError: String?
    let reload: () -> Void

    var body: some View {
        if failure != nil || reconciling {
            Section {
                if let failure {
                    SheetErrorRow(message: failure)
                }
                if reconciling {
                    if let readError {
                        if readError != failure {
                            SheetErrorRow(message: readError)
                        }
                        Button("Reload Details", action: reload)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking the result…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
