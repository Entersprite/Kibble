import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func syncedDrafts(
        at address: ComposerDraftAddress?,
        after cursor: String?
    ) async throws -> SyncedDraftPage {
        let (client, generation) = try await unsentMessageClient()
        return try await readSyncedDrafts(at: address, after: cursor, using: client, generation: generation)
    }
}

extension LocalBridgeBackend {
    func unsentMessageClient() async throws -> (ProtoAPIClient, Int) {
        guard isConnected else { throw ChatError.notAuthenticated }
        let generation = directoryGeneration
        await delivery.recovery?.value
        try checkManagementGeneration(generation)
        guard let apiClient else { throw ChatError.notAuthenticated }
        return (apiClient, generation)
    }

    func readSyncedDrafts(
        at address: ComposerDraftAddress?, after cursor: String?, using client: ProtoAPIClient,
        generation: Int
    ) async throws -> SyncedDraftPage {
        let scope = try Self.draftScope(address)
        let reply: ListUnsentMessagesResponse
        do {
            reply = try await client.call(
                .listUnsentMessages,
                SyncedDraftRequests.list(in: scope, after: cursor)
            )
        } catch let failure as APIFailure {
            throw Self.chatError(fromAPI: failure, call: "loading drafts")
        }
        try checkManagementGeneration(generation)
        let next = reply.nextCursor.isEmpty ? nil : reply.nextCursor
        guard reply.hasRevision, reply.messages.count <= 30, next == nil || next != cursor else {
            throw ChatError.decoding("The service returned an invalid draft page.")
        }
        let drafts = try reply.messages.map(Self.syncedDraft)
        guard Set(drafts.map(\.id)).count == drafts.count,
              address == nil || drafts.allSatisfy({ $0.id.address == address }) else {
            throw ChatError.decoding("The service returned drafts for an unexpected address.")
        }
        return SyncedDraftPage(drafts: drafts, nextCursor: next)
    }

    private static func draftScope(_ address: ComposerDraftAddress?) throws -> SyncedDraftRequests.Scope {
        guard let address else { return .account }
        guard let group = ChannelEventMapping.groupID(for: address.conversation),
              address.thread?.rawValue.isEmpty != true else {
            throw ChatError.decoding("This composer cannot be addressed.")
        }
        guard let thread = address.thread else { return .group(group) }
        return .thread(group: group, topicID: thread.rawValue)
    }

    static func syncedDraft(_ record: UnsentMessage) throws -> SyncedDraft {
        guard record.unsentType == 2, !record.hasDelivery,
              let address = UnsentMessageMapping.address(record.id) else {
            throw ChatError.decoding("The service returned an invalid draft.")
        }
        let body = UnsentMessageMapping.composedBody(record, in: address.conversation)
        let annotationCount = body.mentions.count + (body.content?.formatting.count ?? 0)
            + (body.content?.customEmoji.count ?? 0)
        let canRestore = annotationCount == record.annotations.count
            && (!record.hasReference || body.content?.quote != nil)
            && (try? MessageContentMapping.annotations(body.content?.formatting ?? [], text: body.text)) !=
            nil
            && body.mentions.allSatisfy {
                MessageFormat(style: "", start: $0.start, length: $0.length).range(in: body.text) != nil
            }
        return try SyncedDraft(
            id: SyncedDraft.ID(address: address, record: record.id.localID),
            body: body, modifiedAt: modifiedDate(record),
            changeToken: record.clientSyncValue.isEmpty ? nil : record.clientSyncValue,
            canRestore: canRestore
        )
    }

    private static func modifiedDate(_ record: UnsentMessage) throws -> Date? {
        guard record.hasModifiedTime else { return nil }
        let timestamp = record.modifiedTime
        guard (-62_135_596_800 ... 253_402_300_799).contains(timestamp.seconds),
              (0 ..< 1_000_000_000).contains(timestamp.nanos) else {
            throw ChatError.decoding("The service returned an invalid draft modification time.")
        }
        return Date(timeIntervalSince1970: Double(timestamp.seconds) + Double(timestamp.nanos) / 1e9)
    }
}
