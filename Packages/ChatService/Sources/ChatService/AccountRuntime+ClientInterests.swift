import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func updateClientInterest(
        _ command: ChatCommand, key: ClientInterestKey, sequence: UInt64, backend: any ChatBackend
    ) throws {
        guard interestRevision < UInt64.max else {
            clientInterestsChanged(); throw ServiceFailure.overloaded
        }
        guard var slot = clientInterests[key],
              var lease = slot.lease else { throw ServiceFailure.clientAttachmentExpired }
        guard let scope = ClientHintScope(command) else { throw ServiceFailure.invalidRequest }
        guard try shouldApplyHint(command, sequence: sequence, scope: scope, lease: lease) else { return }
        try applyClientCommand(command, to: &lease)
        let groups = clientInterests.filter { $0.key != key }.values.reduce(lease.conversations) {
            $0.union($1.lease?.conversations ?? [])
        }
        guard backend is any ManagedChatActivityBackend || groups.count <= 1
        else { throw ServiceFailure.unsupportedOperation }
        if case let .setTyping(conversation, thread, true) = command {
            typingRefreshRequested.insert(.init(conversation: conversation, thread: thread))
        }
        lease.hints[scope] = ClientHintStamp(
            sequence: sequence,
            command: command,
            retainUntil: .now + .seconds(120)
        )
        slot.lease = lease
        clientInterests[key] = slot
        clientInterestsChanged()
    }

    private func shouldApplyHint(
        _ command: ChatCommand, sequence: UInt64, scope: ClientHintScope, lease: ClientInterestLease
    ) throws -> Bool {
        if let previous = lease.hints[scope], sequence <= previous.sequence {
            guard sequence < previous.sequence || previous.command == command
            else { throw ServiceFailure.operationConflict }
            return false
        }
        guard lease.hints[scope] != nil || lease.hints.count < 64 else { throw ServiceFailure.overloaded }
        return true
    }

    private func applyClientCommand(_ command: ChatCommand, to lease: inout ClientInterestLease) throws {
        switch command {
        case let .watchPresence(members):
            guard members.count <= 512 else { throw ServiceFailure.overloaded }
            for member in members {
                try validateHintID(member.rawValue)
            }
            lease.presence = Set(members)
        case let .watchConversationActivity(id):
            if let id {
                try validateHintID(id.rawValue)
                guard try storage.conversation(id) != nil else { throw ServiceFailure.invalidRequest }
            }
            lease.conversations = Set(id.map { [$0] } ?? [])
        case let .reportActivity(active): lease.active = active
        case let .setTyping(conversation, thread, active):
            try updateTypingLease(conversation: conversation, thread: thread, active: active, lease: &lease)
        default: throw ServiceFailure.invalidRequest
        }
    }

    private func updateTypingLease(
        conversation: Conversation.ID, thread: MessageThread.ID?, active: Bool,
        lease: inout ClientInterestLease
    ) throws {
        try validateHintID(conversation.rawValue)
        if let thread {
            try validateHintID(thread.rawValue)
        }
        let target = ClientTypingTarget(conversation: conversation, thread: thread)
        if active {
            try authorizePrivacy(target.command(active: true))
            guard lease.typing[target] != nil || lease.typing.count < 8
            else { throw ServiceFailure.overloaded }
            lease.typing[target] = .now + .seconds(6)
        } else {
            lease.typing[target] = nil
        }
    }

    private func validateHintID(_ raw: String) throws {
        guard !raw.isEmpty, raw.utf8.count <= 1024 else { throw ServiceFailure.invalidRequest }
    }

    @discardableResult
    func clientInterestsChanged(force: Bool = false) -> UInt64 {
        // Reaching this limit requires centuries of continuous updates. Retire
        // the runtime rather than allowing a generation to wrap into an old one.
        guard interestRevision < UInt64.max else {
            if interestFault ==
                nil {
                interestFault = Task { [weak self] in await self?.quarantine(.storage) }
            }
            return interestRevision
        }
        interestRevision += 1
        interestDirty = true
        forceInterestPublish = forceInterestPublish || force
        guard interestPublisher == nil, backend != nil, !stopped,
              !quarantinedForSubscription else { return interestRevision }
        interestPublisher = Task { [weak self] in await self?.publishClientInterests() }
        return interestRevision
    }

    func aggregateClientInterests() -> ClientInterestAggregate {
        var aggregate = ClientInterestAggregate()
        let now = ContinuousClock.now
        for slot in clientInterests.values {
            guard let lease = slot.lease, lease.expires > now else { continue }
            aggregate.presence.formUnion(lease.presence)
            aggregate.conversations.formUnion(lease.conversations)
            aggregate.active = aggregate.active || lease.active
            aggregate.typing.formUnion(lease.typing.filter {
                $0.value > now && (try? authorizePrivacy($0.key.command(active: true))) != nil
            }.keys)
        }
        return aggregate
    }

    func clientPolicyChanged() async throws {
        guard interestRevision < UInt64.max else {
            clientInterestsChanged(); throw ServiceFailure.overloaded
        }
        expireClientInterests(at: .now)
        guard backend != nil,
              typingStartInFlight || !publishedInterests.typing.isEmpty || clientInterests.values
              .contains(where: {
                  $0.lease?.typing.isEmpty == false
              }) else { return }
        let target = clientInterestsChanged()
        try await awaitInterestPublication(target)
    }

    func cancelClientInterestJobs() -> [Task<Void, Never>] {
        let tasks = [interestSweep, interestPublisher, interestFault].compactMap(\.self)
        for task in tasks {
            task.cancel()
        }
        for id in Array(interestWaiters.keys) {
            finishInterestWaiter(id, error: CancellationError())
        }
        return tasks
    }
}
