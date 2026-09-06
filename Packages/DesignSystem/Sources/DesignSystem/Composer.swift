import SwiftUI

/// The message field - a floating capsule, the way Messages draws one.
///
/// Deliberately just a field and a send button. Messages also carries an
/// attachments `+`, a dictation waveform and an emoji picker; none of them has
/// a corresponding action on `ChatSceneActions`, and drawing a control that
/// cannot do anything is the same mistake `ChatWindow` already refuses to make
/// with its "cannot send messages yet" text rather than a greyed-out field.
/// When those actions exist they arrive as optional closures and the buttons
/// appear only where a host supplies them - the pattern `StatusStrip` already
/// uses for `signIn`, `signOut` and `reconnect`.
public struct Composer: View {
    let placeholder: String
    let send: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    public init(placeholder: String, send: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.send = send
    }

    public var body: some View {
        HStack(spacing: 6) {
            TextField("Message \(placeholder)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .focused($isFocused)
                .onSubmit(submit)
            // Present only when there is something to send, which is how
            // Messages behaves - and it means the `.return` shortcut exists
            // exactly when it would do something.
            if !trimmed.isEmpty {
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
        .padding(.leading, 14)
        .padding(.trailing, 5)
        // 7.5 above and below a ~16pt line box lands the capsule at 31pt - the
        // measured 30, plus the one point asked for. Half-points are fine: this
        // is 15 device pixels at 2x. Padding rather than a fixed height,
        // because the field grows to six lines.
        .padding(.vertical, 7.5)
        // Real Liquid Glass, not a tinted capsule pretending to be one.
        // `.interactive()` is what gives it the press response; without it the
        // field reads as a static translucent pill.
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .animation(.snappy(duration: 0.15), value: trimmed.isEmpty)
        .onAppear { isFocused = true }
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clears optimistically. The message comes back through the event stream
    /// and lands in the store; the field emptying immediately is what makes the
    /// app feel like it did something.
    private func submit() {
        let text = trimmed
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }
}
