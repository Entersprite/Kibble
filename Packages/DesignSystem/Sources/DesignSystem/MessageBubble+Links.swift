import ChatKit
import SwiftUI

extension MessageBubble {
    var parts: AttachmentLayout.Parts {
        AttachmentLayout.parts(of: linkPresentation.message, canLoadImages: loadAttachment != nil)
    }

    var linkPresentation: MessageLinkPresentation {
        MessageLinkPresentation(message, internalHosts: internalLinkHosts)
    }

    var showsLinkedText: Bool {
        linkPresentation.references.isEmpty || !linkPresentation.message.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var linkQuotes: some View {
        ForEach(linkPresentation.references, id: \.url) { link in
            BubbleWidthLimit(reserve: MessageBubbleLayout.reserve(isMine: message.sender == state.me)) {
                MessageLinkQuote(link: link, me: state.me)
            }
        }
    }
}
