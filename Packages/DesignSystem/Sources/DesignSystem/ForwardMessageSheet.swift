import ChatKit
import SwiftUI

struct ForwardMessageSelection: Identifiable {
    let message: Message
    var id: Message.ID {
        message.id
    }
}

/// Forward…: the message, a conversation to send it to, and an optional
/// comment. Laid out as the conversation sheets are: a `SheetHeader`, and
/// Cancel and Forward in the sheet's own placements at the trailing edge,
/// with Escape and Return.
///
/// The search field leads to the list: Down Arrow moves the keyboard into it,
/// selecting the first conversation when none is, so a destination can be
/// found and chosen without the pointer.
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
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case search, list
    }

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
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Forward Message")
            VStack(alignment: .leading, spacing: 12) {
                MessageQuotePreview(quote: preview, directory: state.directory)
                TextField("Find a conversation", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .onKeyPress(.downArrow) {
                        guard let first = destinations.first else { return .ignored }
                        if destination == nil {
                            destination = first.id
                        }
                        focus = .list
                        return .handled
                    }
                list
                TextField("Add a comment (optional)", text: $comment, axis: .vertical)
                    .lineLimit(2 ... 4).textFieldStyle(.roundedBorder)
                if failed {
                    SheetErrorRow(
                        message: "The message could not be forwarded. Your selection and comment are kept."
                    )
                    .font(.callout)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 540)
        .toolbar { buttons }
        .interactiveDismissDisabled(sending)
    }

    private var list: some View {
        List(selection: $destination) {
            ForEach(destinations, id: \.id) { conversation in
                HStack(spacing: 8) {
                    ConversationPicture(
                        conversation: conversation, directory: state.directory, me: state.me, size: 22
                    )
                    Text(Display.title(of: conversation, directory: state.directory, me: state.me))
                        .lineLimit(1)
                }
                .tag(conversation.id)
            }
        }
        .focused($focus, equals: .list)
        .frame(minHeight: 160, idealHeight: 220, maxHeight: 260)
        .overlay {
            if destinations.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .accessibilityLabel("Forward to conversation")
    }

    @ToolbarContentBuilder private var buttons: some ToolbarContent {
        if sending {
            ToolbarItem(placement: .automatic) {
                ProgressView().controlSize(.small)
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(sending)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Forward") { submit() }
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
