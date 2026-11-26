import ChatKit
import SwiftUI

/// A failed/unknown source stays a small, inert quote. Source snapshots are
/// returned only by the account-owned loader, with no browser fallback.
struct MessageLinkQuote: View {
    let link: MessageLink
    var me: Member.ID?
    @Environment(\.loadMessageReference) private var load
    @Environment(\.messageReferenceDirectory) private var directory
    @Environment(\.messageReferenceScope) private var scope
    @State private var preview: (quote: MessageQuote, author: Member?)?

    var body: some View {
        Group {
            if let preview {
                MessageQuotePreview(
                    quote: preview.quote,
                    directory: authorDirectory(preview.author), me: me
                )
                .modifier(MessageReferenceAction(source: preview.quote))
            } else {
                Label("Message unavailable", systemImage: "quote.opening")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: AccountScoped(account: scope, value: link.messageAddress)) {
            preview = nil
            guard let address = link.messageAddress, let load else { return }
            let result = await load(address)
            guard !Task.isCancelled else { return }
            preview = result
        }
    }

    private func authorDirectory(_ cached: Member?) -> [Member.ID: Member] {
        var result = cached.map { [$0.id: $0] } ?? [:]
        if let id = preview?.quote.sender, let current = directory[id] {
            result[id] = current
        }
        return result
    }
}
