import ChatAPI
import ChatKit
import ChatRules
import Foundation

/// Conversations waiting to be fetched again. Chats a client is viewing have
/// their own lane, fetched as work a person waits for, so they never queue
/// behind the background refetch of other conversations.
struct HistoryRefreshLanes {
    struct Lane {
        var pending: Set<Conversation.ID> = []
        var worker: Task<Void, Never>?
    }

    private var background = Lane()
    private var viewed = Lane()

    var workers: [Task<Void, Never>] {
        [background.worker, viewed.worker].compactMap(\.self)
    }

    subscript(viewed isViewed: Bool) -> Lane {
        get { isViewed ? viewed : background }
        set {
            if isViewed {
                viewed = newValue
            } else {
                background = newValue
            }
        }
    }
}

extension AccountRuntime {
    func scheduleEffects(for event: ChatEvent) async {
        if let member = ownMember(in: event) {
            requestProfileRefresh(member)
        }
        scheduleContinuityEffects(for: event)
        for effect in SyncReducer.reduce(event).effects {
            switch effect {
            case .reloadConversations:
                // A provider that owns checkpoints repairs a gap itself: its
                // recovery replays what changed and withdraws confidence where
                // it cannot, which clears those refill heads. Without
                // checkpoints the gap is the only repair signal, so every
                // recent conversation is fetched again.
                if checkpointedBackend == nil {
                    backfillHeads.removeAll()
                    requestWorldRefresh()
                }
            case let .reloadMessages(id): await scheduleHistoryRefresh(id)
            case .announceArrival, .withdrawAnnouncements: break
            }
        }
    }

    private func scheduleContinuityEffects(for event: ChatEvent) {
        switch event {
        case .conversationsChanged: requestBackfill()
        case .historyInvalidated:
            // The canonical copy no longer confirms any saved row, so a re-send
            // would verify nothing: the refill fetches every recent conversation.
            backfillHeads.removeAll()
            requestBackfill()
        case let .conversationHistoryInvalidated(ids): refreshInvalidatedHistory(ids)
        case .connectionStateChanged(.connected):
            if checkpointedBackend == nil {
                requestWorldRefresh()
            }
            if aggregateClientInterests().hasAny || publishedInterests.hasAny {
                clientInterestsChanged(force: true)
            }
        default: break
        }
    }

    /// Only these conversations lost confidence. One a client is viewing is
    /// fetched again at once; the other recent ones are left to the background
    /// refill, which must fetch them from the provider rather than re-send
    /// saved rows that are no longer confirmed.
    private func refreshInvalidatedHistory(_ ids: [Conversation.ID]) {
        let viewed = aggregateClientInterests().conversations
        for id in ids {
            backfillHeads[id] = nil
            if viewed.contains(id), historyRefresh[viewed: true].pending.count < 1024 {
                historyRefresh[viewed: true].pending.insert(id)
            }
        }
        requestHistoryRefresh(viewed: true)
        requestBackfill()
    }

    private func scheduleHistoryRefresh(_ id: Conversation.ID) async {
        let viewed = aggregateClientInterests().conversations.contains(id)
        guard historyRefresh[viewed: viewed].pending.count < 1024 else {
            await quarantine(.storage)
            return
        }
        historyRefresh[viewed: viewed].pending.insert(id)
        requestHistoryRefresh(viewed: viewed)
    }

    func requestWorldRefresh() {
        guard !stopped, !quarantinedForSubscription else { return }
        worldRefreshRequested = true
        guard worldRefresh == nil else { return }
        worldRefresh = Task {
            defer { worldRefresh = nil }
            while worldRefreshRequested, !stopped, !Task.isCancelled {
                worldRefreshRequested = false
                guard let backend else { return }
                let epoch = currentEpoch
                await reconcileBackground {
                    _ = try await fetchWorld(backend: backend, epoch: epoch, maximumAge: 30)
                }
            }
        }
    }

    /// The account's own member, when `event` names it. A provider may identify
    /// itself by id alone and name its own member later, as any other (the
    /// Google adapter does).
    private func ownMember(in event: ChatEvent) -> Member? {
        switch event {
        case let .selfIdentified(member): member.id == record.selfID ? member : nil
        case let .membersResolved(members), let .membersChanged(_, members):
            members.first { $0.id == record.selfID }
        default: nil
        }
    }

    /// Reports the account's own identity with the provider's organization, if
    /// it states one. Latest member wins; the task drains with the runtime.
    private func requestProfileRefresh(_ member: Member) {
        guard !stopped, !quarantinedForSubscription else { return }
        pendingSelf = member
        guard profileRefresh == nil else { return }
        profileRefresh = Task {
            defer { profileRefresh = nil }
            while let member = pendingSelf, !stopped, !Task.isCancelled {
                pendingSelf = nil
                guard let backend else { return }
                let epoch = currentEpoch
                var organization = AccountOrganization.unstated
                if let source = backend as? any AccountOrganizationBackend {
                    organization = await (try? source.accountOrganization()) ?? .unstated
                }
                guard epoch == currentEpoch, !stopped, !Task.isCancelled else { return }
                await onProfile(AccountProfile(
                    displayName: member.displayName, email: member.email, organization: organization
                ))
            }
        }
    }

    private func requestHistoryRefresh(viewed: Bool) {
        guard historyRefresh[viewed: viewed].worker == nil, !stopped else { return }
        historyRefresh[viewed: viewed].worker = Task {
            defer { historyRefresh[viewed: viewed].worker = nil }
            while let id = historyRefresh[viewed: viewed].pending.first, !stopped, !Task.isCancelled {
                historyRefresh[viewed: viewed].pending.remove(id)
                guard let backend else { return }
                let epoch = currentEpoch
                await reconcileBackground(resource: .history, conversation: id) {
                    _ = try await fetchMessages(
                        in: id, before: nil, backend: backend, epoch: epoch, interactive: viewed
                    )
                }
            }
        }
    }

    func reconciliationFailed(
        _ error: any Error, resource: ResourceSyncStatus.Resource = .directory,
        conversation: Conversation.ID? = nil
    ) async {
        guard !Task.isCancelled, !(error is CancellationError), !stopped,
              !quarantinedForSubscription else { return }
        if error as? ChatError == .sessionExpired {
            await quarantine(.authentication)
        } else {
            do { try recordResourceSync(.init(
                resource: resource, conversationID: conversation, phase: .failed,
                error: error as? ChatError ?? .unknown("The refresh could not complete.")
            )) } catch { await quarantine(.storage) }
        }
    }
}
