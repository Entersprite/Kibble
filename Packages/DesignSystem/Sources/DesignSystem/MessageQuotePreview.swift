import ChatKit
import SwiftUI

public struct ComposerQuoteRequest: Equatable, Sendable {
    public let id = UUID()
    public let quote: MessageQuote

    public init(message: Message) {
        quote = MessageQuote(message: message)
    }
}

struct MessageQuotePreview: View {
    let quote: MessageQuote
    let directory: [Member.ID: Member]
    var cancel: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(directory[quote.sender]?.displayName ?? "Message")
                    .font(.caption.weight(.semibold))
                Text(quote.isDeleted ? "Message deleted" : quote.text.isEmpty ? "Attachment" : quote.text)
                    .font(.callout)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let cancel {
                Button(action: cancel) {
                    Label("Cancel Reply", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
