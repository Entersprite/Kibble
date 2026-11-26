import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func publishClientInterests() async {
        defer { interestPublisher = nil }
        let epoch = currentEpoch
        while interestDirty, !stopped, !quarantinedForSubscription, !Task.isCancelled {
            interestDirty = false
            let revision = interestRevision
            let force = forceInterestPublish
            forceInterestPublish = false
            let refresh = typingRefreshRequested
            typingRefreshRequested = []
            let desired = aggregateClientInterests()
            guard let backend else { return }
            do {
                try checkEpoch(epoch)
                try await publishReceiveInterests(desired, backend: backend, epoch: epoch, force: force)
                try checkEpoch(epoch)
                if force || desired.active != publishedInterests.active {
                    publishedInterests.active = desired.active
                    try await backend.send(.reportActivity(active: desired.active))
                }
                for target in publishedInterests.typing.subtracting(desired.typing) {
                    try checkEpoch(epoch)
                    try await backend.send(target.command(active: false))
                    publishedInterests.typing.remove(target)
                }
                for target in desired.typing
                    where force || refresh.contains(target) || !publishedInterests.typing.contains(target) {
                    try checkEpoch(epoch)
                    try authorizePrivacy(target.command(active: true))
                    publishedInterests.typing.insert(target)
                    typingStartInFlight = true
                    do {
                        try await backend.send(target.command(active: true))
                        typingStartInFlight = false
                    } catch {
                        typingStartInFlight = false
                        throw error
                    }
                }
                try checkEpoch(epoch)
                publishedInterestRevision = revision
                completeInterestWaiters()
            } catch {
                guard !stopped, !quarantinedForSubscription, !Task.isCancelled else { return }
                interestDirty = true
                forceInterestPublish = true
                typingRefreshRequested.formUnion(refresh)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func publishReceiveInterests(
        _ desired: ClientInterestAggregate, backend: any ChatBackend, epoch: UUID, force: Bool
    ) async throws {
        guard force || desired.presence != publishedInterests.presence ||
            desired.conversations != publishedInterests.conversations else { return }
        if let managed = backend as? any ManagedChatActivityBackend {
            try await managed.setReceiveInterests(
                presenceMembers: desired.presence, conversations: desired.conversations
            )
        } else {
            guard desired.conversations.count <= 1 else { throw ServiceFailure.unsupportedOperation }
            try await backend
                .send(.watchPresence(members: desired.presence.sorted { $0.rawValue < $1.rawValue }))
            try checkEpoch(epoch)
            try await backend.send(.watchConversationActivity(conversationID: desired.conversations.first))
        }
        publishedInterests.presence = desired.presence
        publishedInterests.conversations = desired.conversations
    }

    func awaitInterestPublication(_ revision: UInt64) async throws {
        guard publishedInterestRevision < revision else { return }
        guard interestWaiters.count < 32 else { throw ServiceFailure.overloaded }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.finishInterestWaiter(id, error: ServiceFailure.deadlineExceeded)
                }
                interestWaiters[id] = ClientInterestWaiter(
                    revision: revision, continuation: continuation, timeout: timeout
                )
            }
        } onCancel: {
            Task { await self.finishInterestWaiter(id, error: CancellationError()) }
        }
    }

    private func completeInterestWaiters() {
        for (id, waiter) in interestWaiters where waiter.revision <= publishedInterestRevision {
            interestWaiters[id] = nil
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    func finishInterestWaiter(_ id: UUID, error: any Error) {
        guard let waiter = interestWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }
}
