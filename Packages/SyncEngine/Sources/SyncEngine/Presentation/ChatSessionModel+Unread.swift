import ChatKit
import ChatPersistence
import Foundation

public extension ChatSessionModel {
    var visibleUnreadMessages: [Message]? {
        if let inbox = unreadInbox {
            return inbox.messages.filter { !unreadBulkState.covers($0) }
        }
        return unreadBulkState.reads.isEmpty ? nil : []
    }

    var individuallyReadUnreadMessages: [Message] {
        unreadInbox?.readOnThisDevice.filter { !unreadBulkState.covers($0) } ?? []
    }

    func locallyReadForBadge(_ conversation: Conversation) -> Bool {
        guard let cutoff = unreadBulkState.reads[conversation.id]?.main else { return false }
        return (conversation.latestMainMessageAt ?? conversation.lastActivity).map { $0 <= cutoff } ?? true
    }

    func conversationForUnreadDisplay(_ conversation: Conversation) -> Conversation {
        guard locallyReadForBadge(conversation) else { return conversation }
        var displayed = conversation
        displayed.hasUnread = false
        displayed.unreadCount = 0
        displayed.markedUnreadAt = nil
        return displayed
    }

    var unreadConversationIDs: Set<Conversation.ID> {
        guard showingUnread else { return [] }
        return Set(conversations.lazy.filter {
            (UnreadHistoryBasis($0).hasMainUnread && !self.locallyReadForBadge($0)) ||
                self.hasUnrepresentedInboxThreads(in: $0)
        }.map(\.id))
    }

    internal func hasUnrepresentedInboxThreads(in conversation: Conversation) -> Bool {
        guard capabilities.supportsThreads, conversation.repliesEnabled else { return false }
        if unreadBulkState.reads[conversation.id]?.replies != nil,
           !unreadBulkState.reopenedThreads.contains(where: { $0.conversation == conversation.id }) {
            return false
        }
        if unreadInbox?.unreadThreadConversations.contains(conversation.id) == true {
            return true
        }
        return conversation.hasUnreadThread
    }

    func showUnread() {
        guard !showingUnread else { return }
        clearSelection()
        showingUnread = true
        watchUnreadInbox()
    }

    func markInboxMessageRead(_ message: Message) {
        let address = MessageAddress(message)
        guard showingUnread, unreadWork.readTasks[message.id] == nil,
              unreadInbox?.messages.contains(where: { MessageAddress($0) == address }) == true
        else { return }
        unreadWork.readTasks[message.id] = Task { @MainActor [weak self, engine] in
            await engine.markInboxMessageRead(address)
            guard !Task.isCancelled else { return }
            self?.unreadWork.readTasks[message.id] = nil
        }
    }

    func retryUnreadHistory() {
        guard showingUnread, unreadWork.history == nil else { return }
        for id in unreadWork.failed {
            unreadWork.checked[id] = nil
        }
        unreadWork.failed = []
        unreadHistoryFailed = false
        if unreadWork.observation == nil {
            watchUnreadInbox()
        } else {
            loadUnreadHistoryIfNeeded()
        }
    }

    private func watchUnreadInbox() {
        unreadWork.observation = observe(
            store.observeUnreadInbox(),
            onError: { [weak self] in
                self?.unreadWork.observation = nil
                self?.pauseUnreadHistory()
                self?.unreadHistoryFailed = true
            },
            { [weak self] snapshot in
                self?.unreadInbox = snapshot
                self?.loadUnreadHistoryIfNeeded()
            }
        )
    }

    internal func leaveUnread() {
        showingUnread = false
        unreadWork.observation?.cancel()
        unreadWork.observation = nil
        pauseUnreadHistory()
        unreadInbox = nil
        unreadHistoryLoading = false
        unreadHistoryFailed = false
    }

    internal func stopUnread() {
        leaveUnread()
        unreadWork.bulkRead?.cancel()
        unreadWork.saveBulkReads?.cancel()
        isMarkingAllUnread = false
        unreadBulkState = UnreadBulkReadState()
        hasLoadedBulkReads = false
        for task in unreadWork.readTasks.values {
            task.cancel()
        }
        unreadWork = UnreadWork()
    }

    internal func pauseUnreadHistory() {
        unreadWork.history?.cancel()
        unreadWork.history = nil
        unreadHistoryLoading = false
    }

    internal func invalidateUnreadHistory() {
        pauseUnreadHistory()
        unreadWork.checked = [:]
        unreadWork.failed = []
        unreadHistoryFailed = showingUnread && unreadWork.observation == nil
        loadUnreadHistoryIfNeeded()
    }

    internal func loadUnreadHistoryIfNeeded() {
        guard showingUnread, !isMarkingAllUnread, case .connected = connectionState, unreadInbox != nil,
              unreadWork.observation != nil else { return }
        let pending = conversations.compactMap { conversation -> (Conversation, UnreadHistoryBasis)? in
            let basis = UnreadHistoryBasis(conversation)
            guard needsUnreadHistory(conversation, basis: basis),
                  unreadWork.checked[conversation.id] != basis else { return nil }
            return (conversation, basis)
        }
        unreadHistoryFailed = conversations.contains { conversation in
            unreadWork.failed.contains(conversation.id) && needsUnreadHistory(
                conversation,
                basis: UnreadHistoryBasis(conversation)
            )
        }
        guard !pending.isEmpty else {
            pauseUnreadHistory()
            return
        }
        guard unreadWork.history == nil else { return }
        unreadHistoryLoading = true
        unreadWork.history = Task { @MainActor [weak self] in
            for (conversation, basis) in pending {
                guard !Task.isCancelled else { return }
                await self?.checkUnreadHistory(in: conversation, basis: basis)
            }
            guard !Task.isCancelled, let self else { return }
            unreadWork.history = nil
            unreadHistoryLoading = false
            loadUnreadHistoryIfNeeded()
        }
    }

    private func needsUnreadHistory(_ conversation: Conversation, basis: UnreadHistoryBasis) -> Bool {
        basis.canLoadHistory && ((basis.hasMainUnread && !locallyReadForBadge(conversation)) ||
            hasUnrepresentedInboxThreads(in: conversation))
    }

    private func checkUnreadHistory(in conversation: Conversation, basis: UnreadHistoryBasis) async {
        guard conversations.first(where: { $0.id == conversation.id }).map(UnreadHistoryBasis.init)
            == basis else { return }
        do {
            try await engine.loadUnreadHistory(in: conversation)
            guard !Task.isCancelled else { return }
            unreadWork.failed.remove(conversation.id)
        } catch {
            guard !Task.isCancelled else { return }
            unreadWork.failed.insert(conversation.id)
            unreadHistoryFailed = true
        }
        unreadWork.checked[conversation.id] = basis
    }
}

struct UnreadWork {
    var observation: Task<Void, Never>?
    var history: Task<Void, Never>?
    var bulkRead: Task<Void, Never>?
    var saveBulkReads: Task<Void, Never>?
    var dirtyBulkReads: [Conversation.ID: UnreadBulkRead] = [:]
    var unobservedBulkReads: [Conversation.ID: UnreadBulkRead] = [:]
    var persistedBulkReads: [Conversation.ID: UnreadBulkRead] = [:]
    var attemptedBulkReads: [Conversation.ID: UnreadBulkRead] = [:]
    var checked: [Conversation.ID: UnreadHistoryBasis] = [:]
    var failed: Set<Conversation.ID> = []
    var readTasks: [Message.ID: Task<Void, Never>] = [:]
}

struct UnreadHistoryBasis: Equatable, Sendable {
    let hasMainUnread: Bool
    let hasUnreadThread: Bool
    let position: Date?
    let unreadCount: Int
    let head: Date?

    var canLoadHistory: Bool {
        hasUnreadThread || (hasMainUnread && (position != nil || head != nil))
    }

    init(_ conversation: Conversation) {
        hasMainUnread = conversation.hasUnread || conversation.unreadCount > 0 || conversation
            .markedUnreadAt != nil
        hasUnreadThread = conversation.hasUnreadThread
        position = conversation.markedUnreadAt ?? conversation.readPosition
        unreadCount = conversation.unreadCount
        head = hasMainUnread ? conversation.latestMainMessageAt : nil
    }
}
