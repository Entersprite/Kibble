import ChatKit
import SwiftUI

struct ForwardMessageSelection: Identifiable {
    let message: Message
    var id: Message.ID {
        message.id
    }
}

struct ForwardMessageSheet: View {
    let message: Message
    let state: ChatSceneState
    let send: (@MainActor (Message.ID, Conversation.ID, String) async -> Bool)?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var destination: Conversation.ID?
    @State private var comment = ""
    @State private var sending = false
    @State private var failed = false

    private var destinations: [Conversation] {
        state.conversations.filter {
            query.isEmpty || Display.title(of: $0, directory: state.directory, me: state.me)
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var preview: MessageQuote {
        var quote = MessageQuote(message: message)
        if quote.text.isEmpty, message.content?.forwarded != nil {
            quote.text = "Forwarded a message"
        }
        return quote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Forward Message").font(.title2.weight(.semibold))
            MessageQuotePreview(quote: preview, directory: state.directory)
            TextField("Find a conversation", text: $query).textFieldStyle(.roundedBorder)
            List(selection: $destination) {
                ForEach(destinations, id: \.id) { conversation in
                    Text(Display.title(of: conversation, directory: state.directory, me: state.me))
                        .tag(conversation.id)
                }
            }
            .frame(minHeight: 160, idealHeight: 220, maxHeight: 260)
            .overlay {
                if destinations.isEmpty {
                    Text("No conversations found").foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Forward to conversation")
            TextField("Add a comment (optional)", text: $comment, axis: .vertical)
                .lineLimit(2 ... 4).textFieldStyle(.roundedBorder)
            if failed {
                Text("The message could not be forwarded. Your selection and comment are kept.")
                    .font(.callout).foregroundStyle(.red)
            }
            buttons
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 540)
        .interactiveDismissDisabled(sending)
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(sending)
            Spacer()
            if sending {
                ProgressView().controlSize(.small)
            }
            Button("Forward") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(sending || destination == nil || send == nil)
        }
    }

    private func submit() {
        guard !sending, let destination, let send else { return }
        sending = true
        failed = false
        Task { @MainActor in
            let accepted = await send(message.id, destination, comment)
            sending = false
            if accepted {
                dismiss()
            } else {
                failed = true
            }
        }
    }
}
