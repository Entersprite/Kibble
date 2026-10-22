import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func invalidateMediaQueries(for event: ChatEvent) {
        switch event {
        case .messageReceived, .messageUpdated, .messageDeleted, .reactionChanged, .historyLoaded,
             .membersResolved, .selfIdentified, .conversationsChanged, .conversationUpdated,
             .conversationClassified, .historyInvalidated, .conversationHistoryInvalidated,
             .conversationRemoved, .gap:
            mediaFactsVersion = UUID()
        default: break
        }
    }

    func mediaQuery<Value: Sendable>(
        epoch: UUID, urgency: WorkUrgency? = nil, fetch: @Sendable () async throws -> Value,
        remember: @Sendable (any ServiceMediaCatalog, Value, Date) throws -> Void
    ) async throws -> Value {
        for _ in 0 ..< 3 {
            try checkEpoch(epoch)
            let version = mediaFactsVersion
            let value = try await withProviderWork(epoch: epoch, urgency: urgency, fetch)
            try checkEpoch(epoch)
            guard version == mediaFactsVersion else { continue }
            if let catalog = storage as? any ServiceMediaCatalog {
                do {
                    try remember(catalog, value, transferNow())
                    mediaFactsVersion = UUID()
                } catch {
                    await quarantine(.storage)
                    throw error
                }
            }
            return value
        }
        throw ServiceFailure.overloaded
    }

    nonisolated static func rememberDetails(
        _ catalog: any ServiceMediaCatalog, _ rows: [ConversationDetails], at date: Date
    ) throws {
        try catalog.rememberQueryConversations(rows.map(\.conversation), at: date)
        try catalog.rememberQueryMedia(rows.flatMap(\.previewMessages), at: date)
    }
}
