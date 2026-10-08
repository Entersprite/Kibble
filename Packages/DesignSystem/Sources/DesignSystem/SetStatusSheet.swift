import ChatKit
import SwiftUI

/// "Set a status": presets, or your own emoji and text, and when it clears
/// (set-your-status spec §5.2). Save sends and closes; the footer updates
/// when the answer arrives.
struct SetStatusSheet: View {
    let reactions: ReactionActions?
    let save: (MemberStatus?) -> Void
    private let hasStatus: Bool

    @State private var draft: StatusDraft
    @State private var pickingEmoji = false
    @Environment(\.dismiss) private var dismiss

    init(current: MemberStatus?, reactions: ReactionActions?, save: @escaping (MemberStatus?) -> Void) {
        self.reactions = reactions
        self.save = save
        hasStatus = current != nil
        _draft = State(initialValue: StatusDraft(current: current))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set a status").font(.headline)
            HStack(spacing: 8) {
                emojiButton
                TextField("What's your status?", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(StatusPreset.all, id: \.self) { preset in
                    Button("\(preset.emoji)  \(preset.text)") { draft.apply(preset) }
                        .buttonStyle(.plain)
                }
            }
            Picker("Clear after", selection: $draft.expiry) {
                if let kept = draft.keptTitle(now: .now) {
                    Text(kept).tag(StatusExpiry?.none)
                }
                ForEach(StatusExpiry.allCases, id: \.self) { Text($0.title).tag(StatusExpiry?.some($0)) }
            }
            buttons
        }
        .padding(20)
        .frame(width: 360)
    }

    /// The reactions' picker, Unicode only: a custom emoji is ignored (spec §2).
    private var emojiButton: some View {
        Button {
            pickingEmoji = true
        } label: {
            Text(draft.emoji.isEmpty ? "🙂" : draft.emoji).font(.title2)
        }
        .buttonStyle(.borderless)
        .disabled(reactions == nil)
        .help("Choose an emoji")
        .popover(isPresented: $pickingEmoji) {
            if let reactions {
                EmojiPicker(reactions: [], actions: reactions) { choice, _ in
                    if choice.customEmoji == nil {
                        draft.emoji = choice.emoji
                    }
                    pickingEmoji = false
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            if hasStatus {
                Button("Clear") {
                    save(nil)
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                if let status = draft.status(now: .now, calendar: .current) {
                    save(status)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canSave)
        }
    }
}
