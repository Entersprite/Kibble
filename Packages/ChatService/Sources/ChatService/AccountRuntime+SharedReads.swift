import ChatAPI
import ChatKit
import Foundation

struct HistoryReadKey: Hashable {
    let conversation: Conversation.ID
    let before: Message.ID?
    let thread: MessageThread.ID?
    let world: UUID
    let version: UUID?
}

struct FollowedReadVersion: Equatable {
    let world: UUID
    let conversations: [Conversation.ID: UUID]
}

struct AccountReadState {
    var directory: SharedAccountRead<[Conversation]>?
    var directoryVersion: UUID?
    var directoryJobs: [UUID: SharedAccountRead<[Conversation]>] = [:]
    var directoryCompletedAt: Date?
    var providerDirectoryBaseline: [Conversation]?
    var histories: [HistoryReadKey: SharedAccountRead<MessagePage>] = [:]
    var followed: SharedAccountRead<[Message]>?
    var followedVersion: FollowedReadVersion?
    var followedJobs: [UUID: SharedAccountRead<[Message]>] = [:]

    var workers: [Task<Void, Never>] {
        directoryJobs.values.map(\.worker) + followedJobs.values.map(\.worker) + histories.values
            .map(\.worker)
    }
}

extension AccountRuntime {
    func fetchWorld(
        backend: any ChatBackend, epoch: UUID, maximumAge: TimeInterval = 0
    ) async throws -> [Conversation] {
        try checkEpoch(epoch)
        guard maximumAge.isFinite, (0 ... 300).contains(maximumAge) else {
            throw ServiceFailure.invalidRequest
        }
        if let pending = reads.directory, reads.directoryVersion == worldVersion {
            return try await pending.value()
        }
        if maximumAge > 0, let date = reads.directoryCompletedAt,
           now().timeIntervalSince(date) >= 0, now().timeIntervalSince(date) < maximumAge {
            return try storage.conversations()
        }
        guard reads.directoryJobs.count < 8 else { throw ServiceFailure.overloaded }
        let id = UUID()
        let pending = SharedAccountRead(id: id) {
            try await self.readWorld(backend: backend, epoch: epoch, job: id)
        }
        reads.directory = pending
        reads.directoryVersion = worldVersion
        reads.directoryJobs[id] = pending
        return try await pending.value()
    }

    func readWorld(backend: any ChatBackend, epoch: UUID, job: UUID) async throws -> [Conversation] {
        defer {
            reads.directoryJobs[job] = nil
            if reads.directory?.id == job {
                reads.directory = nil
            }
        }
        let result = try await reconcileWorld(backend: backend, epoch: epoch)
        if reads.directory?.id == job {
            reads.directoryCompletedAt = now()
        }
        return result
    }

    func fetchMessages(
        in conversation: Conversation.ID, before: Message.ID?, thread: MessageThread.ID? = nil,
        backend: any ChatBackend, epoch: UUID
    ) async throws -> MessagePage {
        try checkEpoch(epoch)
        let key = HistoryReadKey(
            conversation: conversation, before: before, thread: thread,
            world: historyWorldVersion, version: historyVersions[conversation]
        )
        if let pending = reads.histories[key] {
            return try await pending.value()
        }
        guard reads.histories.count < 32 else { throw ServiceFailure.overloaded }
        let id = UUID()
        let pending = SharedAccountRead(id: id) {
            try await self.readHistory(key, backend: backend, epoch: epoch, job: id)
        }
        reads.histories[key] = pending
        return try await pending.value()
    }

    private func readHistory(
        _ key: HistoryReadKey, backend: any ChatBackend, epoch: UUID, job: UUID
    ) async throws -> MessagePage {
        defer {
            if reads.histories[key]?.id == job {
                reads.histories[key] = nil
            }
        }
        return try await reconcileMessages(
            in: key.conversation, before: key.before, thread: key.thread, backend: backend, epoch: epoch
        )
    }

    func fetchFollowedThreads(backend: any ChatBackend, epoch: UUID) async throws -> [Message] {
        try checkEpoch(epoch)
        let version = FollowedReadVersion(world: historyWorldVersion, conversations: historyVersions)
        if let pending = reads.followed, reads.followedVersion == version {
            return try await pending.value()
        }
        guard reads.followedJobs.count < 8 else { throw ServiceFailure.overloaded }
        let id = UUID()
        let pending = SharedAccountRead(id: id) {
            try await self.readFollowed(backend: backend, epoch: epoch, job: id)
        }
        reads.followed = pending
        reads.followedVersion = version
        reads.followedJobs[id] = pending
        return try await pending.value()
    }

    private func readFollowed(backend: any ChatBackend, epoch: UUID, job: UUID) async throws -> [Message] {
        defer {
            reads.followedJobs[job] = nil
            if reads.followed?.id == job {
                reads.followed = nil
            }
        }
        return try await reconcileFollowedThreads(backend: backend, epoch: epoch)
    }
}
