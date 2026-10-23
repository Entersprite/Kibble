import ChatKit
import SwiftUI

/// What Convert to Space sends: a name, an optional single emoji, and the
/// history acknowledgement. The name's length is counted in UTF-16 units
/// against the server's limit, without the spaces around it, which aren't sent.
struct ConversionDraft: Equatable {
    var name: String
    /// One character, or nil (or "") for the default icon.
    var emoji: String?
    var acknowledged = false

    init(name: String) {
        self.name = name
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isNameValid(limit: Int?) -> Bool {
        let name = trimmedName
        return !name.isEmpty && (limit.map { DetailsDraft.length(name) <= $0 } ?? true)
    }

    /// Whether Convert can be offered: the consequences have arrived, the
    /// name is valid, and the acknowledgement is ticked if they require it.
    func isReady(limit: Int?, conversion: ConversionConsequences?) -> Bool {
        guard let conversion else { return false }
        return isNameValid(limit: limit) && (acknowledged || !conversion.requiresHistoryAcknowledgement)
    }

    /// Takes a picked emoji only if it is the one character the server accepts.
    mutating func choose(_ emoji: String?) {
        guard let emoji, emoji.count == 1 else { return }
        self.emoji = emoji
    }

    var mutation: ConversationMutation {
        .convertToSpace(
            name: trimmedName,
            emoji: emoji.flatMap { $0.isEmpty ? nil : $0 },
            acknowledgingHistoryChange: true
        )
    }
}

/// Convert “<title>” to a Space, a sheet over the Info sheet: an emoji tile
/// and a name, what the server says converting does, and the history
/// acknowledgement when it requires one. Cancel and Convert.
///
/// Convert sends at once and the sheet stays until the server answers, as
/// the webhook editor does. A confirmed conversion closes it; the Info sheet
/// shows the space only once the details read back say so. A refusal or an
/// unconfirmed answer stays here with what was typed, and the details are
/// read again before Convert is offered another time: never a blind retry.
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

    private var limit: Int? {
        details.fieldLimits["name"]
    }

    /// `mutate` drops a write while one is on its way or the details need reloading.
    private var busy: Bool {
        browser.isSubmitting || browser.needsReconciliation || browser.isLoadingAllParticipants
    }

    private var canConvert: Bool {
        draft.isReady(limit: limit, conversion: browser.conversion) && !sent && !busy
    }

    /// The details are being read again and nothing has failed since.
    private var checking: Bool {
        browser.needsReconciliation && browser.panelError == nil
    }

    var body: some View {
        Form {
            identity.disabled(sent)
            consequences
            if browser.conversion?.requiresHistoryAcknowledgement == true {
                Section {
                    Toggle(
                        "I understand the conversation history setting will change",
                        isOn: $draft.acknowledged
                    )
                    .toggleStyle(.checkbox)
                }
                .disabled(sent)
            }
            outcome
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
        guard let current = browser.details,
              current.conversation.id == details.conversation.id else { return nil }
        return current.conversation.kind
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

    /// The confirmed lines, then what can't be confirmed; while they load,
    /// a small progress indicator, and a failed read can be tried again.
    @ViewBuilder private var consequences: some View {
        if let conversion = browser.conversion {
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
        } else if let error = browser.conversionError {
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

    /// A refusal or an unconfirmed answer, then the details being read
    /// again; a failed read offers Reload Details, a read and never the write.
    @ViewBuilder private var outcome: some View {
        let reconciling = browser.needsReconciliation && !browser.isSubmitting && !sent
        if failure != nil || reconciling {
            Section {
                if let failure {
                    SheetErrorRow(message: failure)
                }
                if reconciling {
                    if checking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking the result…").foregroundStyle(.secondary)
                        }
                    } else {
                        if let error = browser.panelError, error != failure {
                            SheetErrorRow(message: error)
                        }
                        Button("Reload Details") { check() }
                    }
                }
            }
        }
    }

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

    /// Reads the open conversation's details again: a read, never the write.
    private func check() {
        actions.details(browser.panelTarget ?? details.conversation.id, false)
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
        ToolbarItem(placement: .confirmationAction) {
            Button("Convert", action: convert)
                .disabled(!canConvert)
        }
    }
}
