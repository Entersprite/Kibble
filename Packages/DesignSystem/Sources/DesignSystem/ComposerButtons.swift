import SwiftUI

/// A round glass button beside the field, as Messages draws its + and emoji
/// buttons. A label rather than a bare image, so VoiceOver reads the title.
struct ComposerRoundButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: ComposerLayout.lineHeight, height: ComposerLayout.lineHeight)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(title)
    }
}

/// The emoji button and its picker, which opens to the left of the button as
/// Messages' does. Standard emoji only: a custom one needs an annotation the
/// composer does not build.
struct ComposerEmojiButton: View {
    let reactions: ReactionActions
    let pick: (String) -> Void
    /// The picker closed, picked from or not.
    let closed: () -> Void

    @State private var picking = false

    var body: some View {
        ComposerRoundButton(title: "Emoji", systemImage: ComposerLayout.emojiSymbol) {
            picking = true
        }
        .popover(isPresented: $picking, arrowEdge: .leading) {
            EmojiPicker(reactions: [], actions: reactions, offersCustom: false) { choice, _ in
                picking = false
                pick(choice.emoji)
            }
        }
        .onChange(of: picking) { _, open in
            if !open {
                closed()
            }
        }
    }
}

/// Messages' waveform, inside the field while it is empty
/// (`ComposerLayout.offersDictation`).
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
