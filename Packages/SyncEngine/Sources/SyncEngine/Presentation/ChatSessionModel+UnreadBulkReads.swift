import ChatKit
import ChatPersistence
import Foundation

extension ChatSessionModel {
    /// Applies a device-local read before the database or provider can suspend.
    public func markAllUnreadMessagesRead(
        in allowed: Set<Conversation.ID>, restrictingTo scope: Set<Conversation.ID>? = nil,
        includingReplies: Bool = true
    ) {
        guard showingUnread else { return }
        let visible = (visibleUnreadMessages ?? []) + individuallyReadUnreadMessages
        let grouped = Dictionary(grouping: visible, by: \.conversationID)
        let candidates = unreadConversationIDs.union(grouped.keys)
        // Use the replica's time precision so its first observation retires the immediate overlay.
        let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970)
        var changes: [Conversation.ID: UnreadBulkRead] = [:]
        for row in conversations where candidates.contains(row.id) && (scope?.contains(row.id) ?? true) {
            let messages = grouped[row.id] ?? []
            let target = InboxReadTarget(messages: messages, head: nil)
            let hasMain = !locallyReadForBadge(row) && UnreadHistoryBasis(row).hasMainUnread
            let head = row.latestMainMessageAt
            let main = hasMain || target.main != nil ? max(head ?? now, target.main ?? .distantPast) : nil
            let hasReplies = includingReplies &&
                (!target.replies.isEmpty || hasUnrepresentedInboxThreads(in: row))
            let replies = hasReplies ? max(now, target.replies.values.max() ?? now) : nil
            guard main != nil || replies != nil else { continue }
            let publishes = capabilities.canMarkRead && allowed.contains(row.id)
            changes[row.id] = UnreadBulkRead(
                main: main, replies: replies, pendingMain: publishes ? main : nil,
                pendingReplies: publishes && capabilities.supportsThreads ? replies : nil,
                confirmedMain: publishes && main != nil ? head : nil
            )
        }
        guard !changes.isEmpty else { return }
        unreadBulkState.merge(changes)
        unreadWork.unobservedBulkReads.merge(changes) { $0.merging($1) }
        unreadWork.dirtyBulkReads.merge(changes) { $0.merging($1) }
        pauseUnreadHistory()
        if unreadConversationIDs.isEmpty, visibleUnreadMessages?.isEmpty == true {
            unreadHistoryFailed = false
        }
        loadUnreadHistoryIfNeeded()
        savePendingUnreadBulkReads()
    }

    func watchUnreadBulkReads() {
        watch(store.observeUnreadBulkReads()) { [weak self] stored in
            guard let self else { return }
            unreadWork.persistedBulkReads = stored.reads
            unreadWork.unobservedBulkReads = unreadWork.unobservedBulkReads.filter { id, local in
                let committed = stored.reads[id]
                return (local.main.map { (committed?.main ?? .distantPast) < $0 } ?? false) ||
                    (local.replies.map { (committed?.replies ?? .distantPast) < $0 } ?? false)
            }
            unreadBulkState = stored
            unreadBulkState.merge(unreadWork.unobservedBulkReads)
            hasLoadedBulkReads = true
            syncUnreadBulkReads()
        }
    }

    func savePendingUnreadBulkReads() {
        guard unreadWork.saveBulkReads == nil, !unreadWork.dirtyBulkReads.isEmpty else { return }
        let changes = unreadWork.dirtyBulkReads
        unreadWork.dirtyBulkReads = [:]
        unreadWork.saveBulkReads = Task { @MainActor [weak self, engine] in
            do {
                try await engine.persistUnreadBulkReads(changes)
                guard let self, !Task.isCancelled else { return }
                unreadWork.saveBulkReads = nil
                savePendingUnreadBulkReads()
            } catch {
                guard let self, !Task.isCancelled else { return }
                unreadWork.saveBulkReads = nil
                unreadWork.dirtyBulkReads.merge(changes) { $0.merging($1) }
                lastError = error as? ChatError ?? .unknown("Couldn’t save the local read state.")
            }
        }
    }

    public func syncUnreadBulkReads() {
        guard case .connected = connectionState, capabilities.canMarkRead,
              unreadWork.bulkRead == nil else { return }
        let pending = pendingBulkReceipts()
        guard !pending.isEmpty else { return }
        for (row, read) in pending {
            unreadWork.attemptedBulkReads[row.id] = read
        }
        isMarkingAllUnread = true
        unreadWork.bulkRead = Task { @MainActor [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (index, pair) in pending.enumerated() {
                    if index >= 4 {
                        await group.next()
                    }
                    guard !Task.isCancelled else { break }
                    group.addTask { [weak self] in
                        await self?.submitUnreadBulkRead(pair.1, in: pair.0)
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            unreadWork.bulkRead = nil
            isMarkingAllUnread = false
            syncUnreadBulkReads()
            loadUnreadHistoryIfNeeded()
        }
    }

    private func pendingBulkReceipts() -> [(Conversation, UnreadBulkRead)] {
        let policy = engine.readReceipts.policy
        return conversations.compactMap { row in
            guard let local = unreadWork.persistedBulkReads[row.id],
                  local.pendingMain != nil || local.pendingReplies != nil,
                  unreadWork.attemptedBulkReads[row.id] != local else { return nil }
            switch policy {
            case .withhold: return nil
            case let .resolve(settings) where !settings.resolve(for: row).readReceipts: return nil
            default: return (row, local)
            }
        }
    }

    private func submitUnreadBulkRead(_ read: UnreadBulkRead, in conversation: Conversation) async {
        let id = conversation.id
        while let previous = conversationActionTasks[id] ?? markTasks[id] {
            await previous.value
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled, conversations.contains(where: { $0.id == id }) else { return }
        let task = scheduleExplicitRead(in: id, delay: .zero) { model in
            await model.publishUnreadBulkRead(read, in: id)
        }
        await task?.value
    }

    private func publishUnreadBulkRead(_ read: UnreadBulkRead, in id: Conversation.ID) async {
        let target = await engine.bulkReceiptTargets(in: id, for: read)
        guard !Task.isCancelled else { return }
        do {
            try await Task.sleep(for: inboxReadDelay(through: target.latest))
        } catch {
            return
        }
        let current = await engine.validateUnreadBulkReceipts(target, in: id, for: read)
        await publishInboxRead(current, in: id)
        await engine.reconcileUnreadBulkRead(in: id, for: read)
    }
}
