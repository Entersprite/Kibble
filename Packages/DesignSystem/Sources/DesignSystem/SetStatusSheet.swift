import ChatKit
import SwiftUI

/// "Set a Status": presets, or your own emoji and text, and when it clears
/// (set-your-status spec §5.2). Save sends and closes; the footer updates
/// when the answer arrives.
///
/// A grouped form, with its buttons in the sheet's own placements: Cancel
/// and Save at the trailing edge, and Clear Status, while a status is set,
/// at the leading edge, where macOS puts a destructive action in a sheet.
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

    static let title = "Set a Status"
    /// The emoji button's picture before one is chosen. Checked to exist by
    /// `SidebarSymbolTests`; on macOS 26 and 27 it draws the filled face.
    static let emojiSymbol = "face.smiling"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    emojiButton
                    TextField("Status", text: $draft.text, prompt: Text("What's your status?"))
                        .labelsHidden()
                }
            }
            Section("Suggestions") {
                ForEach(StatusPreset.all, id: \.self) { preset in
                    Button { draft.apply(preset) } label: { suggestion(preset) }
                        .buttonStyle(.plain)
                }
            }
            Section {
                Picker("Clear after", selection: $draft.expiry) {
                    if let kept = draft.keptTitle(now: .now) {
                        Text(kept).tag(StatusExpiry?.none)
                    }
                    ForEach(StatusExpiry.allCases, id: \.self) { Text($0.title).tag(StatusExpiry?.some($0)) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .safeAreaBar(edge: .top) { SheetHeader(title: Self.title) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    // The end is counted from the click, not from when the
                    // sheet opened.
                    if let status = draft.status(now: .now, calendar: .current) {
                        save(status)
                    }
                    dismiss()
                }
                .disabled(!draft.canSave)
            }
            if hasStatus {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear Status") {
                        save(nil)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 400)
    }

    /// A preset, and how long it lasts once chosen.
    private func suggestion(_ preset: StatusPreset) -> some View {
        LabeledContent {
            Text(preset.expiry.title)
        } label: {
            Text("\(preset.emoji)  \(preset.text)")
                .foregroundStyle(.primary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Fills in this status")
    }

    /// The reactions' picker, Unicode only: a custom emoji is ignored (spec §2).
    private var emojiButton: some View {
        Button {
            pickingEmoji = true
        } label: {
            if draft.emoji.isEmpty {
                Label("Choose Emoji", systemImage: Self.emojiSymbol)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .font(.title2)
            } else {
                Text(draft.emoji)
                    .font(.title2)
                    .accessibilityLabel("Emoji \(draft.emoji)")
            }
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
}
