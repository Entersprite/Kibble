import ChatKit

public extension FakeBackend {
    func send(_ command: ChatCommand, consuming draft: SyncedDraft) async throws -> Bool {
        try requireConnected()
        try require(capabilities.canSendSavedDraft, "sendSavedDraft")
        guard draft.canConsume(
                  with: command,
                  allowingAttachments: capabilities.canSendSavedDraftWithAttachments
              ),
              case let .sendMessage(
                  conversation,
                  thread,
                  text,
                  localID,
                  attachments,
                  mentions,
                  content
              ) = command
        else { throw ChatError.decoding("Invalid saved draft submission.") }
        try command.validateMessageContent(capabilities: capabilities)
        let address = draft.id.address
        let previous = SyncedDraftChange(address: address, previous: draft, body: nil)
        let indices = world.syncedDrafts.indices.filter { world.syncedDrafts[$0].id.address == address }
        let ownedIndex = indices.count == 1 ? indices.first : nil
        try sendMessage(
            in: conversation, thread: thread, body: ComposedMessage(
                text: text,
                mentions: mentions,
                content: content
            ),
            localID: localID, attachments: attachments
        )
        guard let ownedIndex, world.syncedDrafts[ownedIndex].canRestore,
              previous.matches(world.syncedDrafts[ownedIndex]) else { return false }
        world.syncedDrafts.remove(at: ownedIndex)
        emit(.unsentMessagesChanged(.init(address: address, drafts: true, scheduled: false)))
        return true
    }

    func syncedDrafts(at address: ComposerDraftAddress?, after cursor: String?) throws -> SyncedDraftPage {
        try requireConnected()
        try require(capabilities.canReadSyncedDrafts, "syncedDraftReads")
        let drafts = world.syncedDrafts.filter { address == nil || $0.id.address == address }
        let start: Int
        if let cursor {
            guard let index = Int(cursor), index > 0, index < drafts.count else {
                throw ChatError.decoding("This draft page is unavailable.")
            }
            start = index
        } else {
            start = 0
        }
        let end = min(start + 30, drafts.count)
        return SyncedDraftPage(
            drafts: Array(drafts[start ..< end]), nextCursor: end == drafts.count ? nil : String(end)
        )
    }

    func writeSyncedDraft(
        _ change: SyncedDraftChange,
        operationID _: String
    ) throws -> SyncedDraftWriteResult {
        try requireConnected()
        try require(capabilities.canWriteSyncedDrafts, "syncedDraftWrites")
        try change.validate(capabilities: capabilities)
        let matching = world.syncedDrafts.indices
            .filter { world.syncedDrafts[$0].id.address == change.address }
        guard matching.count <= 1 else { throw ChatError.decoding("This composer has multiple drafts.") }
        let index = matching.first
        let current = index.map { world.syncedDrafts[$0] }
        if change.body == nil && current == nil {
            return SyncedDraftWriteResult(applied: true, current: nil)
        }
        guard change.matches(current), change.body == nil || current?.canRestore != false else {
            return SyncedDraftWriteResult(applied: false, current: current)
        }
        guard let body = change.body else {
            if let index {
                world.syncedDrafts.remove(at: index)
                emit(.unsentMessagesChanged(.init(address: change.address, drafts: true, scheduled: false)))
            }
            return SyncedDraftWriteResult(applied: true, current: nil)
        }
        if current?.body == body {
            return SyncedDraftWriteResult(applied: true, current: current)
        }
        let draft = SyncedDraft(
            id: current?.id ?? .init(address: change.address, record: nextIdentifier("draft")),
            body: body,
            modifiedAt: advance(),
            changeToken: nextIdentifier("draft-change")
        )
        if let index {
            world.syncedDrafts[index] = draft
        } else {
            world.syncedDrafts.append(draft)
        }
        emit(.unsentMessagesChanged(.init(address: change.address, drafts: true, scheduled: false)))
        return SyncedDraftWriteResult(applied: true, current: draft)
    }
}
