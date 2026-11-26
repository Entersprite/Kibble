import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

extension SQLiteAccountStorage: ServicePinnedMediaCatalog {
    public func rememberPinnedMedia(
        _ messages: [Message], in conversation: Conversation.ID, at date: Date
    ) throws {
        guard messages.count <= 100, Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ $0.conversationID == conversation && !$0.isDeleted })
        else { throw ServiceFailure.invalidResponse }
        try database.write { db in
            let keeping = messages.map(\.id.rawValue)
            let removed = keeping.isEmpty ? "" :
                "AND originID NOT IN (\(databaseQuestionMarks(count: keeping.count)))"
            try db.execute(sql: """
            DELETE FROM serviceMediaReference WHERE originKind = 'pinMessage' AND conversationID = ? \(
                removed
            )
            """, arguments: StatementArguments([conversation.rawValue] + keeping))
            for message in messages {
                let sources = ProviderMediaSource.collect(
                    attachments: message.attachments, reactions: message.reactions,
                    links: message.links, cards: message.cards, forwarded: message.content?.forwarded,
                    customEmoji: message.content?.customEmoji.map(\.emoji) ?? []
                )
                try Self.replaceMediaSources(sources, facts: MediaIndexFacts(
                    origin: .pinnedMessage(conversation, message.id), canonical: false,
                    createdAt: message.createdAt.timeIntervalSince1970,
                    expiry: date.addingTimeInterval(900).timeIntervalSince1970,
                    touchedAt: date.timeIntervalSince1970
                ), db: db)
            }
            try Self.trimMediaCatalog(db)
        }
    }
}
