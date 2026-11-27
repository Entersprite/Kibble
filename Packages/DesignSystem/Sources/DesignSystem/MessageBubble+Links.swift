import ChatKit
import SwiftUI

extension MessageBubble {
    var parts: AttachmentLayout.Parts {
        AttachmentLayout.parts(of: linkPresentation.message, canLoadImages: loadAttachment != nil)
    }

    var linkPresentation: MessageLinkPresentation {
        MessageLinkPresentation(message, internalHosts: internalLinkHosts, meetingHosts: meetingLinkHosts)
    }

    var showsLinkedText: Bool {
        (linkPresentation.references.isEmpty && linkPresentation.meetings.isEmpty) || !linkPresentation
            .message.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var linkQuotes: some View {
        ForEach(linkPresentation.references, id: \.url) { link in
            BubbleWidthLimit(reserve: MessageBubbleLayout.reserve(isMine: message.sender == state.me)) {
                MessageLinkQuote(link: link, me: state.me)
            }
        }
    }

    func meetingCards(menu: MessageMenuContext) -> some View {
        ForEach(linkPresentation.meetings, id: \.url) { link in
            MeetingLinkCard(link: link, text: message.text, messageDate: message.createdAt)
                .modifier(ReactionMenu(context: menu, link: link.url))
        }
    }
}
