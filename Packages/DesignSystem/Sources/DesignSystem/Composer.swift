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
/// Who the `@` list offers, or `nil` for no list: the backend cannot mention
/// (`Capabilities.canMention`), or the platform has no text view for tokens.
public struct ComposerMentions: Equatable {
    public var candidates: [Member]
    public var includeAll: Bool

    public init(candidates: [Member], includeAll: Bool) {
        self.candidates = candidates
        self.includeAll = includeAll
    }
}

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

    @State private var draft = ComposerDraft()
    @FocusState private var isFocused: Bool

    public init(
        placeholder: String,
        restoring: ComposedMessage? = nil,
        onRestored: (() -> Void)? = nil,
        attachments: [ComposerAttachment] = [],
        attachmentActions: ComposerAttachmentActions? = nil,
        mentions: ComposerMentions? = nil,
        send: @escaping (ComposedMessage) -> Void
    ) {
        self.placeholder = placeholder
        self.restoring = restoring
        self.onRestored = onRestored
        self.attachments = attachments
        self.attachmentActions = attachmentActions
        self.mentions = mentions
        self.send = send
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ComposerAttachmentStrip(attachments: attachments) { attachmentActions?.remove($0) }
            }
            field
        }
        .padding(.leading, attachmentActions == nil ? 14 : 8)
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
            in: attachments.isEmpty ? AnyShape(.capsule) : AnyShape(.rect(cornerRadius: 18))
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .animation(.snappy(duration: 0.15), value: canSubmit)
        .animation(.snappy(duration: 0.15), value: attachments.map(\.id))
        .onAppear { isFocused = true }
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
        .onChange(of: restoring, initial: true) { _, text in
            guard draft.adopt(text) else { return }
            isFocused = true
            onRestored?()
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            if let attachmentActions {
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
            TextField(
                "Message \(placeholder)",
                text: Binding(get: { draft.text }, set: { draft.edit($0) }),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1 ... 6)
            .focused($isFocused)
            .onSubmit(submit)
            // Present only when there is something to send, which is how
            // Messages behaves - and it means the `.return` shortcut exists
            // exactly when it would do something.
            if canSubmit {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .transition(.scale.combined(with: .opacity))
            }
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
    private func submit() {
        guard canSubmit else { return }
        let message = draft.composed()
        draft.clear()
        send(message)
    }
}
