import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

extension SQLiteAccountStorage: ServiceMediaCatalog {
    static let mediaVisibility = """
    FROM serviceMediaReference AS media
    LEFT JOIN conversation ON conversation.id = media.conversationID
    LEFT JOIN message ON message.id = media.messageID
    LEFT JOIN member ON member.id = media.memberID
    LEFT JOIN conversationActionState AS action ON action.id = media.conversationID
    WHERE media.expiresAt > ? AND (
        (media.originKind = 'member' AND (media.memberID IS NULL OR member.id IS NOT NULL))
        OR (media.originKind IN ('message', 'conversation')
            AND (conversation.id IS NOT NULL OR media.canonical = 0)
            AND COALESCE(action.isRemoved, 0) = 0
            AND (media.messageID IS NULL OR (message.id IS NOT NULL AND message.isDeleted = 0))
            AND (media.originKind = 'conversation' OR action.historyClearedBefore IS NULL
                OR media.createdAt > action.historyClearedBefore))
    )
    """

    public func mediaSources(for selector: MediaSelector, at date: Date) throws -> [IssuedMediaSource] {
        if case .unknown = selector {
            throw ServiceFailure.unsupportedOperation
        }
        let key = try ServiceCodec.encode(selector)
        guard key.count <= 32768 else { throw ServiceFailure.invalidRequest }
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT media.* \(Self.mediaVisibility) AND media.sourceKey = ?
            ORDER BY media.touchedAt DESC, media.originID LIMIT 64
            """, arguments: [date.timeIntervalSince1970, key])
            return try rows.map { row in
                try IssuedMediaSource(
                    origin: Self.mediaOrigin(row),
                    source: Self.decodeMediaSource(selector, from: row["value"]),
                    version: row["version"]
                )
            }
        }
    }

    public func isCurrentMediaSource(_ source: IssuedMediaSource, at date: Date) throws -> Bool {
        let key = try ServiceCodec.encode(source.source.selector)
        let origin = Self.mediaOriginFields(source.origin)
        return try database.read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 \(Self.mediaVisibility)
                AND media.sourceKey = ? AND media.originKind = ? AND media.originID = ?
                AND media.conversationID = ? AND media.version = ?)
            """, arguments: [
                date.timeIntervalSince1970,
                key,
                origin.kind,
                origin.id,
                origin.conversation,
                source.version
            ]) == true
        }
    }

    public func rememberQueryMedia(_ messages: [Message], at date: Date) throws {
        try database.write { db in
            for message in messages where !message.isDeleted {
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM message WHERE id = ?)",
                    arguments: [message.id.rawValue]
                ) != true else { continue }
                let sources = ProviderMediaSource.collect(
                    attachments: message.attachments, reactions: message.reactions,
                    links: message.links, cards: message.cards
                )
                try Self.replaceMediaSources(
                    sources, facts: MediaIndexFacts(
                        origin: .message(message.conversationID, message.id),
                        canonical: false,
                        createdAt: message.createdAt.timeIntervalSince1970,
                        expiry: date.addingTimeInterval(900).timeIntervalSince1970,
                        touchedAt: date.timeIntervalSince1970
                    ), db: db
                )
            }
            try Self.trimMediaCatalog(db)
        }
    }

    public func rememberQueryConversations(_ conversations: [Conversation], at date: Date) throws {
        try database.write { db in
            for conversation in conversations {
                guard let url = conversation.avatarURL else { continue }
                try Self.replaceMediaSources(
                    [.remoteImage(url)], facts: MediaIndexFacts(
                        origin: .conversation(conversation.id), canonical: false, createdAt: 0,
                        expiry: date.addingTimeInterval(900).timeIntervalSince1970,
                        touchedAt: date.timeIntervalSince1970
                    ), db: db
                )
            }
            try Self.trimMediaCatalog(db)
        }
    }

    public func rememberQueryMembers(_ members: [Member], at date: Date) throws {
        try database.write { db in
            for member in members {
                guard let url = member.avatarURL else { continue }
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM member WHERE id = ?)",
                    arguments: [member.id.rawValue]
                ) == true
                try Self.replaceMediaSources(
                    [.remoteImage(url)], facts: MediaIndexFacts(
                        origin: .member(member.id), canonical: exists, createdAt: 0,
                        expiry: date.addingTimeInterval(900).timeIntervalSince1970,
                        touchedAt: date.timeIntervalSince1970
                    ), db: db
                )
            }
            try Self.trimMediaCatalog(db)
        }
    }

    static func decodeMediaSource(_ selector: MediaSelector, from data: Data) throws -> ProviderMediaSource {
        switch selector {
        case .attachment: try .attachment(ServiceCodec.decode(Attachment.self, from: data))
        case .customEmoji: try .customEmoji(ServiceCodec.decode(CustomEmojiRef.self, from: data))
        case .remoteImage: try .remoteImage(ServiceCodec.decode(URL.self, from: data))
        case .unknown: throw ServiceFailure.unsupportedOperation
        }
    }
}
