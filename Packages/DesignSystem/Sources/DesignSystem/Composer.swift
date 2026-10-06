import ChatKit
import SwiftUI

/// The message field - a floating capsule, the way Messages draws one.
///
/// A field, a send button, and a paperclip with the staged files above the
/// field when the host supplies `attachmentActions`. Messages also carries a
/// dictation waveform and an emoji picker; neither has a corresponding action
/// on `ChatSceneActions`, and drawing a control that cannot do anything is the
/// same mistake `ChatWindow` already refuses to make with its "cannot send
/// messages yet" text rather than a greyed-out field. When those actions exist
/// they arrive as optional closures and the buttons appear only where a host
/// supplies them - the pattern the paperclip and `StatusStrip` follow.
public struct Composer: View {
    let placeholder: String
    let send: (ComposedMessage) -> Void

    /// A failed send, mentions and all, offered back for this composer to
    /// adopt. `nil` in every ordinary frame - see `ComposerDraft`.
    let restoring: ComposedMessage?
    /// Told once `restoring` has been adopted, so the host can stop offering
    /// it. **Optional, and its absence is the point**: a host with no restore
    /// hook simply gets the old behaviour.
    let onRestored: (() -> Void)?
    /// The files staged in this conversation, drawn above the field.
    let attachments: [ComposerAttachment]
    /// `nil` draws no paperclip and lets no file be removed.
    let attachmentActions: ComposerAttachmentActions?
    /// `nil` offers no `@` list.
    let mentions: ComposerMentions?
    /// `nil` offers no edit mode (edit spec §5).
    let editing: ComposerEditing?

    @State private var draft = ComposerDraft()
    @FocusState private var isFocused: Bool
    /// Bumped to put the caret in the macOS field (`ComposerTextView`).
    @State private var focusRequest = 0
    @State private var highlighted = 0
    /// The `@` whose list Esc closed, so it stays closed until a new `@`.
    @State private var dismissedAt: Int?
    @State private var anchorX: CGFloat = 0
    @State private var sendGate = ComposerSendGate()
    @State private var pendingInvite: PendingInvite?
    /// The message whose membership check is out, so a composer torn down
    /// meanwhile can hand it back.
    @State private var checking: ComposedMessage?

    public init(
        placeholder: String,
        restoring: ComposedMessage? = nil,
        onRestored: (() -> Void)? = nil,
        attachments: [ComposerAttachment] = [],
        attachmentActions: ComposerAttachmentActions? = nil,
        mentions: ComposerMentions? = nil,
        editing: ComposerEditing? = nil,
        send: @escaping (ComposedMessage) -> Void
    ) {
        self.placeholder = placeholder
        self.restoring = restoring
        self.onRestored = onRestored
        self.attachments = attachments
        self.attachmentActions = attachmentActions
        self.mentions = mentions
        self.editing = editing
        self.send = send
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // While editing, the bar replaces the staged files: they stay
            // staged, and are never sent with the edit (edit spec §5).
            if draft.editing != nil {
                ComposerEditBar(cancel: cancelEdit)
            } else if !attachments.isEmpty {
                ComposerAttachmentStrip(attachments: attachments) { attachmentActions?.remove($0) }
            }
            field
        }
        .padding(.leading, showsPaperclip ? 8 : 14)
        .padding(.trailing, 5)
        // 7.5 above and below a ~16pt line box lands the capsule at 31pt - the
        // measured 30, plus the one point asked for. Half-points are fine: this
        // is 15 device pixels at 2x. Padding rather than a fixed height,
        // because the field grows to six lines.
        .padding(.vertical, 7.5)
        // Real Liquid Glass, not a tinted capsule pretending to be one.
        // `.interactive()` is what gives it the press response; without it the
        // field reads as a static translucent pill. A rounded rectangle once
        // files are staged: a capsule 70pt tall is a pill with no straight
        // edge for the chips to sit on.
        .glassEffect(
            .regular.interactive(),
            in: attachments.isEmpty && draft
                .editing == nil ? AnyShape(.capsule) : AnyShape(.rect(cornerRadius: 18))
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .animation(.snappy(duration: 0.15), value: canAct)
        .animation(.snappy(duration: 0.15), value: attachments.map(\.id))
        .overlayPreferenceValue(ComposerFieldAnchor.self) { anchor in
            suggestionList(above: anchor)
        }
        .onChange(of: draft.activeQuery) { _, query in
            mentions?.queryChanged?(query?.text)
            highlighted = 0
            if query?.location != dismissedAt {
                dismissedAt = nil
            }
        }
        .onAppear {
            isFocused = true
            focusRequest += 1
        }
        // **`initial: true` is load-bearing, not decoration.** `ChatWindow`
        // keys this view `.id(conversation.id)`, so returning to a
        // conversation after a failed send tears down the old `Composer` and
        // constructs a brand new one whose `restoring` is *already*
        // `state.failedDraft` on its very first render - an initial value,
        // not a change. Plain `.onChange(of:)` never fires for a value a view
        // already holds on first appearance, so without `initial: true` the
        // adopt-once logic below never runs on exactly the path the feature
        // exists for: navigate away, come back, and the draft would render
        // empty. A fresh composer for a conversation with no failed draft
        // still adopts nothing (`restoring == nil`, `adopt(nil)` returns
        // `false`), and a later redraw carrying the same non-nil value still
        // cannot re-adopt (`ComposerDraft.adopted` remembers) - so this is
        // safe to fire unconditionally on appearance.
        // Torn down with a message unsent (another conversation was opened
        // mid-check, or with the confirmation up): it goes back to this
        // conversation's draft rather than being lost (review finding 2).
        .onDisappear {
            if let unsent = pendingInvite?.message ?? checking {
                mentions?.keepHere?(unsent)
            }
        }
        .confirmationDialog(
            pendingInvite.map(inviteTitle) ?? "",
            isPresented: Binding(get: { pendingInvite != nil }, set: {
                if !$0 {
                    pendingInvite = nil
                }
            }),
            presenting: pendingInvite
        ) { invite in
            Button("Add and send") { finish(invite.message.settingMode(.invite, for: invite.people)) }
            Button("Send without adding") { finish(invite.message.settingMode(
                .withoutAdding,
                for: invite.people
            )) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Adding them lets them see this message.")
        }
        .onChange(of: editing?.request, initial: true) { _, request in
            begin(request)
        }
        .onChange(of: restoring, initial: true) { _, text in
            guard draft.adopt(text) else { return }
            isFocused = true
            focusRequest += 1
            onRestored?()
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            if let attachmentActions, draft.editing == nil {
                // A label rather than a bare image, so VoiceOver reads the words.
                Button(action: attachmentActions.choose) {
                    Label("Attach Files…", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach Files…")
            }
            text
                .anchorPreference(key: ComposerFieldAnchor.self, value: .bounds) { $0 }
            // Present only when there is something to send, which is how
            // Messages behaves - and it means the `.return` shortcut exists
            // exactly when it would do something.
            if canAct {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                }
                .buttonStyle(.plain)
                #if !os(macOS)
                    // Not on macOS: a key equivalent is checked before the
                    // first responder, so it would send while the `@` list is
                    // open and Return should pick. The text view handles
                    // Return there (`ComposerTextView`).
                    .keyboardShortcut(.return, modifiers: [])
                #endif
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// The field: an `NSTextView` on macOS, for tokens and a caret the `@`
    /// list can follow; a `TextField` elsewhere, with no mentions.
    @ViewBuilder private var text: some View {
        #if os(macOS)
            ComposerTextView(
                draft: $draft,
                anchorX: $anchorX,
                placeholder: "Message \(placeholder)",
                listOpen: !suggestions.isEmpty,
                focusRequest: focusRequest,
                onKey: handle,
                onSubmit: submit,
                upEdits: ComposerEditKeys.upEdits(
                    draft: draft, stagedCount: attachments.count, listOpen: !suggestions.isEmpty,
                    newest: editing?.newest
                ),
                escCancels: ComposerEditKeys.escCancels(draft: draft, listOpen: !suggestions.isEmpty)
            )
            .overlay(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text("Message \(placeholder)")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
        #else
            TextField(
                "Message \(placeholder)",
                text: Binding(get: { draft.text }, set: { draft.edit($0) }),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1 ... 6)
            .focused($isFocused)
            .onSubmit(submit)
        #endif
    }

    /// A pure filter over observed candidates, so computing it per render
    /// reads no store (CLAUDE.md, session 46). Empty hides the list: no
    /// match, no `@`, Esc, or a backend that cannot mention.
    private var suggestions: [MentionSuggestion] {
        guard let mentions, let query = draft.activeQuery, query.location != dismissedAt else { return [] }
        return MentionSuggestions.suggestions(
            for: query.text, candidates: mentions.candidates, includeAll: mentions.includeAll,
            // Members only while editing: an edit never adds anyone.
            directory: draft.editing == nil ? mentions.directory : []
        )
    }

    /// Bottom-aligned in a frame that ends 8pt above the field, so the list
    /// grows upwards over the transcript, starting at the `@`.
    private func suggestionList(above anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            let rows = suggestions
            if let anchor, !rows.isEmpty {
                let field = proxy[anchor]
                ZStack(alignment: .bottomLeading) {
                    MentionSuggestionList(
                        suggestions: rows, highlighted: min(highlighted, rows.count - 1), pick: pick
                    )
                    .padding(.leading, min(field.minX + anchorX, max(0, proxy.size.width - 288)))
                }
                .frame(width: proxy.size.width, height: max(0, field.minY - 8), alignment: .bottomLeading)
            }
        }
    }

    #if os(macOS)
        private func handle(_ key: ComposerKey) {
            let rows = suggestions
            switch key {
            case .up: highlighted = max(0, highlighted - 1)
            case .down: highlighted = min(rows.count - 1, highlighted + 1)
            case .pick: if rows.indices.contains(highlighted) {
                    pick(rows[highlighted])
                }
            case .dismiss: dismissedAt = draft.activeQuery?.location
            case .editNewest:
                if let newest = editing?.newest {
                    begin(ComposerEditRequest(
                        messageID: newest.id,
                        message: ComposedMessage(text: newest.text, mentions: newest.mentions)
                    ))
                }
            case .cancelEdit: cancelEdit()
            }
        }
    #endif

    private func pick(_ suggestion: MentionSuggestion) {
        draft.pick(suggestion.target, name: suggestion.name)
        highlighted = 0
        if suggestion.outsideConversation, case let .user(id) = suggestion.target {
            mentions?.outsidePicked?(id)
        }
    }

    private var trimmed: String {
        draft.composed().text
    }

    /// Text, or a staged file that is not already on its way.
    private var canSubmit: Bool {
        !trimmed.isEmpty || attachments.contains { !$0.isUploading }
    }

    /// Clears optimistically. The message comes back through the event stream
    /// and lands in the store; the field emptying immediately is what makes the
    /// app feel like it did something.
    /// Without a way to ask who is outside, sends at once. With one, asks;
    /// anyone outside brings up the confirmation (mention non-members spec
    /// §2). One Return at a time, and the draft cleared only if it still says
    /// what was sent (review focus 3 and 4).
    private func submit() {
        switch ComposerEditKeys.submitAction(draft: draft, canSend: canSubmit) {
        case .nothing:
            return
        case .save:
            if let ended = draft.endEditing() {
                editing?.save(ended.messageID, ended.message)
                editing?.ended()
            }
            return
        case .send:
            break
        }
        let message = draft.composed()
        guard let ask = mentions?.nonMembers else {
            draft.clear()
            send(message)
            return
        }
        guard sendGate.begin() else { return }
        checking = message
        Task { @MainActor in
            defer {
                sendGate.end()
                checking = nil
            }
            let outside = await ask(message)
            if outside.isEmpty {
                finish(message)
            } else {
                pendingInvite = PendingInvite(message: message, people: outside)
            }
        }
    }

    /// Return does something: sends, or saves an edit.
    private var canAct: Bool {
        ComposerEditKeys.submitAction(draft: draft, canSend: canSubmit) != .nothing
    }

    private var showsPaperclip: Bool {
        attachmentActions != nil && draft.editing == nil
    }

    private func begin(_ request: ComposerEditRequest?) {
        guard let request, let editing else { return }
        draft.beginEditing(request.messageID, with: request.message)
        editing.began(request.messageID)
        isFocused = true
        focusRequest += 1
    }

    private func cancelEdit() {
        guard draft.endEditing() != nil else { return }
        editing?.ended()
    }

    private func finish(_ message: ComposedMessage) {
        if ComposerSendGate.clears(draft: draft.composed(), sent: message) {
            draft.clear()
        }
        if let sendHere = mentions?.sendHere {
            sendHere(message)
        } else {
            send(message)
        }
    }

    private func inviteTitle(_ invite: PendingInvite) -> String {
        let names = ListFormatter.localizedString(byJoining: invite.message.names(of: invite.people))
        return "\(names) " + (invite.people.count == 1 ? "isn't" : "aren't") + " in this space."
    }
}
