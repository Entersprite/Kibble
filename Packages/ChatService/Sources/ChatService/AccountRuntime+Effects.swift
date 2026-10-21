import ChatAPI
import ChatKit
import ChatRules
import Foundation

extension AccountRuntime {
    func scheduleEffects(for event: ChatEvent) async {
        if let member = ownMember(in: event) {
            requestProfileRefresh(member)
        }
        scheduleContinuityEffects(for: event)
        for effect in SyncReducer.reduce(event).effects {
            switch effect {
            case .reloadConversations:
                backfillHeads.removeAll()
                if checkpointedBackend == nil {
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
        case .historyInvalidated: requestBackfill(replay: true)
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

    private func scheduleHistoryRefresh(_ id: Conversation.ID) async {
        guard pendingHistory.count < 1024 else {
            await quarantine(.storage)
            return
        }
        pendingHistory.insert(id)
        requestHistoryRefresh()
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

    private func requestHistoryRefresh() {
        guard historyRefresh == nil, !stopped else { return }
        historyRefresh = Task {
            defer { historyRefresh = nil }
            while let id = pendingHistory.first, !stopped, !Task.isCancelled {
                pendingHistory.remove(id)
                guard let backend else { return }
                let epoch = currentEpoch
                await reconcileBackground(resource: .history, conversation: id) {
                    _ = try await fetchMessages(in: id, before: nil, backend: backend, epoch: epoch)
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
