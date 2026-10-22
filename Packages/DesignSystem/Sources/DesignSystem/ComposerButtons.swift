import ChatKit
import SwiftUI

/// A round glass button, as Messages draws its + and emoji buttons beside the
/// field. A label rather than a bare image, so VoiceOver reads the title.
struct RoundGlassButton: View {
    let title: String
    let systemImage: String
    var diameter: CGFloat = ComposerLayout.lineHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(title)
    }
}

/// The emoji button and its picker, which opens to the left of the button as
/// Messages' does. Custom choices are offered when this host can send
/// their typed annotations.
struct ComposerEmojiButton: View {
    let reactions: ReactionActions
    /// The field takes focus back through the insertion. Closed without a
    /// pick, nothing refocuses it: the button never took first responder, so
    /// the field still has it, and a click that closed the picker may have
    /// given it to another field (review finding 1).
    let pick: (ReactionChoice) -> Void

    @State private var picking = false

    var body: some View {
        RoundGlassButton(title: "Emoji", systemImage: ComposerLayout.emojiSymbol) {
            picking = true
        }
        .popover(isPresented: $picking, arrowEdge: .leading) {
            EmojiPicker(
                reactions: [],
                actions: reactions,
                use: reactions.canComposeCustomEmoji ? .reaction : .text
            ) { choice, _ in
                picking = false
                pick(choice)
            }
        }
    }
}

/// Start Dictation, inside the field while it is empty
/// (`ComposerLayout.offersDictation`), where Messages draws its waveform.
struct ComposerDictationButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Start Dictation", systemImage: ComposerLayout.dictationSymbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                // A line's height, so the field keeps its own.
                .frame(height: 16)
        }
        .buttonStyle(.plain)
        .help("Start Dictation")
    }
}

/// The send arrow, off the Mac only: Messages on the Mac has none, and Return
/// sends there (`ComposerTextView` handles it). The composer shows it only
/// when there is something to send, so the `.return` shortcut exists exactly
/// when it would do something.
struct ComposerSendButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
    }
}
