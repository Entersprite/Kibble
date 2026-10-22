import ChatKit
import SwiftUI

public struct ComposerQuoteRequest: Equatable, Sendable {
    public let id = UUID()
    public let quote: MessageQuote

    public init(message: Message) {
        quote = MessageQuote(message: message)
    }
}

/// A quoted message: its author's picture and name over its text. Above a
/// reply it is as wide as its words, up to a bubble's widest; with a Cancel
/// button (the composer's reply), or when asked to, it spans its column.
struct MessageQuotePreview: View {
    let quote: MessageQuote
    let directory: [Member.ID: Member]
    var me: Member.ID?
    var fillsWidth = false
    var cancel: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                if let author = Self.author(of: quote, directory: directory, me: me) {
                    HStack(spacing: 5) {
                        Avatar(member: quote.sender, directory: directory, size: 16)
                            .accessibilityHidden(true)
                        Text(author)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                Text(Self.text(of: quote))
                    .font(.callout)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
            if fillsWidth || cancel != nil {
                Spacer(minLength: 0)
            }
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

    /// The author's name, "You" for your own message when the directory has
    /// no name for you, and `nil` for someone it cannot name: the quote then
    /// shows its text alone rather than a word standing in for a name.
    static func author(of quote: MessageQuote, directory: [Member.ID: Member], me: Member.ID?) -> String? {
        guard !quote.sender.rawValue.isEmpty else { return nil }
        if Display.hasName(of: quote.sender, in: directory) {
            return Display.name(of: quote.sender, in: directory)
        }
        return quote.sender == me ? "You" : nil
    }

    static func text(of quote: MessageQuote) -> String {
        quote.isDeleted ? "Message deleted" : quote.text.isEmpty ? "Attachment" : quote.text
    }
}
