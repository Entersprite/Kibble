import SwiftUI

/// The message field.
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
        HStack(spacing: 8) {
            TextField("Message \(placeholder)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .focused($isFocused)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderless)
            .disabled(trimmed.isEmpty)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
