import ChatKit
import Observation

@MainActor
@Observable
public final class BlockedListSessionState<Row: Identifiable & Sendable> where Row.ID: Sendable {
    public enum Failure: Equatable, Sendable {
        case load, unblock
    }

    public internal(set) var rows: [Row]?
    public internal(set) var isLoading = false
    public internal(set) var pending: Row.ID?
    public internal(set) var failure: Failure?
    @ObservationIgnored var work: Task<Void, Never>?

    func stop() {
        work?.cancel()
        work = nil
        rows = nil
        isLoading = false
        pending = nil
        failure = nil
    }

    func update(unblocking id: Row.ID?, read: @escaping @MainActor () async throws -> [Row]) {
        guard work == nil else { return }
        isLoading = id == nil
        pending = id
        failure = nil
        work = Task { [weak self] in
            let result = try? await read()
            guard let self, !Task.isCancelled else { return }
            work = nil
            isLoading = false
            pending = nil
            if let result {
                rows = result
            } else {
                failure = id == nil ? .load : .unblock
            }
        }
    }
}

public typealias BlockedConversationsSessionState = BlockedListSessionState<BlockedConversation>

public extension ChatSessionModel {
    func refreshBlockedConversations() {
        changeBlockedConversations(unblocking: nil)
    }

    func unblockConversation(_ id: Conversation.ID) {
        guard blockedRooms.rows?.contains(where: { $0.id == id }) == true else { return }
        changeBlockedConversations(unblocking: id)
    }

    private func changeBlockedConversations(unblocking id: Conversation.ID?) {
        guard capabilities.canManageBlockedConversations, isClientTransportAvailable else { return }
        blockedRooms.update(unblocking: id) { [engine] in
            try await engine.blockedConversations(unblocking: id)
        }
    }

    func refreshBlockedPeople() {
        changeBlockedPeople(unblocking: nil)
    }

    func unblockPerson(_ id: Member.ID) {
        guard blockedPeople.rows?.contains(where: { $0.id == id }) == true else { return }
        changeBlockedPeople(unblocking: id)
    }

    private func changeBlockedPeople(unblocking id: Member.ID?) {
        guard capabilities.canManageBlockedPeople, isClientTransportAvailable else { return }
        blockedPeople.update(unblocking: id) { [engine] in
            try await engine.blockedPeople(unblocking: id)
        }
    }
}
