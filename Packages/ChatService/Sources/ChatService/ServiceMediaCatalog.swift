import ChatAPI
import ChatKit
import Foundation

/// Issued facts retained by the service, never constructed from a request's body.
public enum ProviderMediaSource: Hashable, Sendable {
    case attachment(Attachment)
    case customEmoji(CustomEmojiRef)
    case remoteImage(URL)

    public var selector: MediaSelector {
        switch self {
        case let .attachment(value): .attachment(value.id)
        case let .customEmoji(value): .customEmoji(value.id)
        case let .remoteImage(url): .remoteImage(url.absoluteURL)
        }
    }

    public static func collect(
        attachments: [Attachment], reactions: [Reaction], links: [MessageLink], cards: [AppCard],
        forwarded: ForwardedMessage? = nil
    ) -> [ProviderMediaSource] {
        var values = attachments.filter { !$0.id.isEmpty }.map(Self.attachment)
        values += reactions.compactMap(\.customEmoji)
            .filter { $0.imageToken?.isEmpty == false && !$0.id.isEmpty }.map(Self.customEmoji)
        var urls = links.compactMap { $0.preview?.imageURL }
        for card in cards {
            if let url = card.header?.imageURL {
                urls.append(url)
            }
            for widget in card.sections.flatMap(\.widgets) {
                switch widget {
                case let .image(picture): urls.append(picture.url)
                case let .decorated(row): if let url = row.iconURL {
                        urls.append(url)
                    }
                default: break
                }
            }
        }
        if let forwarded, !forwarded.source.isDeleted {
            values += forwarded.attachments.filter { !$0.id.isEmpty }.map(Self.attachment)
            urls += forwarded.links.compactMap { $0.preview?.imageURL }
        }
        if let url = forwarded?.senderAvatarURL {
            urls.append(url)
        }
        values += urls.filter { $0.scheme?.lowercased() == "https" }.map { .remoteImage($0.absoluteURL) }
        return values
    }
}

public enum IssuedMediaOrigin: Hashable, Sendable {
    case message(Conversation.ID, Message.ID)
    case member(Member.ID)
    case conversation(Conversation.ID)
}

public struct IssuedMediaSource: Sendable {
    public let origin: IssuedMediaOrigin
    public let source: ProviderMediaSource
    public let version: String

    public init(origin: IssuedMediaOrigin, source: ProviderMediaSource, version: String) {
        self.origin = origin
        self.source = source
        self.version = version
    }
}

public protocol ServiceMediaCatalog: Sendable {
    func mediaSources(for selector: MediaSelector, at: Date) throws -> [IssuedMediaSource]
    func isCurrentMediaSource(_ source: IssuedMediaSource, at: Date) throws -> Bool
    func rememberQueryMedia(_ messages: [Message], at: Date) throws
    func rememberQueryConversations(_ conversations: [Conversation], at: Date) throws
    func rememberQueryMembers(_ members: [Member], at: Date) throws
}
