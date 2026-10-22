import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

struct MediaOriginFields {
    let kind: String
    let id: String
    let conversation: String
    let messageID: String?
    let memberID: String?
}

struct MediaIndexFacts {
    let origin: IssuedMediaOrigin
    let canonical: Bool
    let createdAt: Double
    let expiry: Double
    let touchedAt: Double
}

extension SQLiteAccountStorage {
    static func updateMediaCatalog(_ event: ChatEvent, db: Database) throws {
        switch event {
        case let .messageReceived(message), let .messageUpdated(message):
            try indexStoredMedia(message.id.rawValue, db: db)
        case let .historyLoaded(update):
            for id in Set(update.messages.map(\.id.rawValue)) {
                try indexStoredMedia(id, db: db)
            }
        case let .messageDeleted(id, _), let .reactionChanged(id, _): try indexStoredMedia(
                id.rawValue,
                db: db
            )
        default: try updateProfileMedia(event, db: db)
        }
        try trimMediaCatalog(db)
    }

    private static func updateProfileMedia(_ event: ChatEvent, db: Database) throws {
        switch event {
        case let .membersResolved(members):
            for member in members {
                try indexProfileMedia(member.id.rawValue, member: true, db: db)
            }
        case let .selfIdentified(member): try indexProfileMedia(member.id.rawValue, member: true, db: db)
        case let .conversationUpdated(row), let .conversationClassified(row): try indexProfileMedia(
                row.id.rawValue,
                member: false,
                db: db
            )
        case let .conversationsChanged(rows):
            try db.execute(sql: """
            DELETE FROM serviceMediaReference WHERE originKind IN ('message', 'conversation') AND NOT EXISTS (
                SELECT 1 FROM conversation WHERE conversation.id = serviceMediaReference.conversationID
            )
            """)
            for row in rows {
                try indexProfileMedia(row.id.rawValue, member: false, db: db)
            }
        case .historyInvalidated:
            try db.execute(sql: "DELETE FROM serviceMediaReference WHERE originKind = 'message'")
        case let .conversationHistoryInvalidated(ids) where !ids.isEmpty:
            try db.execute(
                sql: """
                DELETE FROM serviceMediaReference WHERE originKind = 'message'
                AND conversationID IN (\(databaseQuestionMarks(count: ids.count)))
                """,
                arguments: StatementArguments(ids.map(\.rawValue))
            )
        case let .conversationRemoved(id, _):
            try db.execute(
                sql: "DELETE FROM serviceMediaReference WHERE conversationID = ?",
                arguments: [id.rawValue]
            )
        default: return
        }
    }

    static func indexStoredMedia(_ id: String, db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: """
        SELECT conversationID, attachments, reactions, links, cards, content, createdAt FROM message
        WHERE id = ? AND isDeleted = 0
        """, arguments: [id]) else {
            try db.execute(
                sql: "DELETE FROM serviceMediaReference WHERE originKind = 'message' AND originID = ?",
                arguments: [id]
            )
            return
        }
        let contentJSON: String? = row["content"]
        let content = try contentJSON
            .map { try ServiceCodec.decode(MessageContent.self, from: Data($0.utf8)) }
        let sources = try ProviderMediaSource.collect(
            attachments: decodeMediaColumn([Attachment].self, row: row, key: "attachments"),
            reactions: decodeMediaColumn([Reaction].self, row: row, key: "reactions"),
            links: decodeMediaColumn([MessageLink].self, row: row, key: "links"),
            cards: decodeMediaColumn([AppCard].self, row: row, key: "cards"),
            forwarded: content?.forwarded
        )
        try replaceMediaSources(
            sources,
            facts: MediaIndexFacts(
                origin: .message(.init(row["conversationID"]), .init(id)), canonical: true,
                createdAt: row["createdAt"], expiry: 253_402_300_799,
                touchedAt: Date().timeIntervalSince1970
            ), db: db
        )
    }

    static func indexProfileMedia(_ id: String, member: Bool, db: Database) throws {
        let table = member ? "member" : "conversation"
        let row = try Row.fetchOne(db, sql: "SELECT avatarURL FROM \(table) WHERE id = ?", arguments: [id])
        let url = (row?["avatarURL"] as String?).flatMap(URL.init(string:))
        try replaceMediaSources(
            url.map { [.remoteImage($0)] } ?? [],
            facts: MediaIndexFacts(
                origin: member ? .member(.init(id)) : .conversation(.init(id)), canonical: true,
                createdAt: 0, expiry: 253_402_300_799,
                touchedAt: Date().timeIntervalSince1970
            ), db: db
        )
    }

    static func replaceMediaSources(
        _ sources: [ProviderMediaSource], facts: MediaIndexFacts, db: Database
    ) throws {
        let fields = mediaOriginFields(facts.origin)
        let old = try Row.fetchAll(
            db,
            sql: """
            SELECT sourceKey, value, version FROM serviceMediaReference WHERE originKind = ? AND originID = ?
            """,
            arguments: [fields.kind, fields.id]
        )
        let versions = Dictionary(uniqueKeysWithValues: old.map { row in
            (row["sourceKey"] as Data, (row["value"] as Data, row["version"] as String))
        })
        try db.execute(
            sql: "DELETE FROM serviceMediaReference WHERE originKind = ? AND originID = ?",
            arguments: [fields.kind, fields.id]
        )
        var unique: [MediaSelector: ProviderMediaSource] = [:]
        for source in sources {
            if case let .remoteImage(url) = source, url.scheme?.lowercased() != "https" {
                continue
            }
            unique[source.selector] = source
        }
        for source in unique.values {
            let key = try ServiceCodec.encode(source.selector)
            let value = try encodeMediaSource(source)
            guard key.count <= 32768, value.count <= 65536 else { continue }
            let version = versions[key].flatMap { $0.0 == value ? $0.1 : nil } ?? UUID().uuidString
            try db.execute(sql: """
            INSERT INTO serviceMediaReference
                (sourceKey, originKind, originID, conversationID, canonical, messageID, memberID,
                 value, version,
                 createdAt, expiresAt, touchedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                key,
                fields.kind,
                fields.id,
                fields.conversation,
                facts.canonical,
                facts.canonical ? fields.messageID : nil,
                facts.canonical ? fields.memberID : nil,
                value,
                version,
                facts.createdAt,
                facts.expiry,
                facts.touchedAt
            ])
        }
    }

    static func encodeMediaSource(_ source: ProviderMediaSource) throws -> Data {
        switch source {
        case let .attachment(value): try ServiceCodec.encode(value)
        case let .customEmoji(value): try ServiceCodec.encode(value)
        case let .remoteImage(value): try ServiceCodec.encode(value)
        }
    }

    static func mediaOriginFields(_ origin: IssuedMediaOrigin) -> MediaOriginFields {
        switch origin {
        case let .message(conversation, id):
            MediaOriginFields(
                kind: "message",
                id: id.rawValue,
                conversation: conversation.rawValue,
                messageID: id.rawValue,
                memberID: nil
            )
        case let .member(id): MediaOriginFields(
                kind: "member",
                id: id.rawValue,
                conversation: "",
                messageID: nil,
                memberID: id.rawValue
            )
        case let .conversation(id): MediaOriginFields(
                kind: "conversation",
                id: id.rawValue,
                conversation: id.rawValue,
                messageID: nil,
                memberID: nil
            )
        }
    }

    static func mediaOrigin(_ row: Row) throws -> IssuedMediaOrigin {
        switch row["originKind"] as String {
        case "message": .message(.init(row["conversationID"]), .init(row["originID"]))
        case "member": .member(.init(row["originID"]))
        case "conversation": .conversation(.init(row["originID"]))
        default: throw ServiceFailure.invalidResponse
        }
    }

    static func decodeMediaColumn<T: Decodable>(_ type: T.Type, row: Row, key: String) throws -> T {
        let json: String = row[key]
        return try ServiceCodec.decode(type, from: Data(json.utf8))
    }
}
