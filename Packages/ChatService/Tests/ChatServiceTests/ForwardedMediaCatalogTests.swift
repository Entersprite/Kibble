import ChatAPI
import ChatKit
import ChatService
import Foundation
import Testing
@testable import ChatServiceStorage

struct ForwardedMediaCatalogTests {
    @Test func receivedForwardAuthorizesItsSnapshotOnlyInTheReceivingConversation() throws {
        let source = sourceMessage()
        let image = try #require(URL(string: "https://images.example.test/forward.png"))
        let avatar = try #require(URL(string: "https://images.example.test/author.png"))
        let attachment = Attachment(id: "forward-file", name: "Plan", contentType: "text/plain")
        var received = try Message(
            id: .init("received"), conversationID: .init("destination"), threadID: .init("outer-thread"),
            sender: .init("forwarder"), text: "Comment", createdAt: Date(timeIntervalSince1970: 2),
            content: MessageContent(forwarded: ForwardedMessage(
                source: MessageQuote(message: source), senderAvatarURL: avatar,
                attachments: [attachment], links: [MessageLink(
                    url: #require(URL(string: "https://example.test/plan")), preview: .init(
                        title: "Plan",
                        imageURL: image
                    )
                )]
            ))
        )
        for canonical in [false, true] {
            let store = try SQLiteAccountStorage(account: .init("account"), path: ":memory:")
            _ = try store.append(
                .conversationsChanged([Conversation(id: received.conversationID, kind: .space)]),
                live: false
            )
            if canonical {
                _ = try store.append(.messageReceived(received), live: true)
            } else {
                try store.rememberQueryMedia([received], at: Date())
            }
            for selector in [
                MediaSelector.attachment(attachment.id),
                .remoteImage(image),
                .remoteImage(avatar)
            ] {
                let issued = try #require(store.mediaSources(for: selector, at: Date()).first)
                #expect(issued.origin == .message(received.conversationID, received.id))
            }
            received.content?.forwarded?.source.isDeleted = true
            if canonical {
                _ = try store.append(.messageUpdated(received), live: true)
                #expect(try store.mediaSources(for: .attachment(attachment.id), at: Date()).isEmpty)
                #expect(try store.mediaSources(for: .remoteImage(image), at: Date()).isEmpty)
                _ = try store.append(
                    .messageDeleted(id: received.id, in: received.conversationID),
                    live: true
                )
                #expect(try store.mediaSources(for: .remoteImage(avatar), at: Date()).isEmpty)
            }
            received.content?.forwarded?.source.isDeleted = false
        }
    }

    private func sourceMessage() -> Message {
        Message(
            id: .init("source"), conversationID: .init("inaccessible-source"), threadID: .init("thread"),
            sender: .init("author"), text: "Original", createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
