import ChatAPI
import ChatKit
import ChatRules
import Foundation

extension AccountRuntime {
    func scheduleEffects(for event: ChatEvent) async {
        switch event {
        case .conversationsChanged: requestBackfill()
        case .connectionStateChanged(.connected): requestWorldRefresh()
        default: break
        }
        for effect in SyncReducer.reduce(event).effects {
            switch effect {
            case .reloadConversations:
                backfillHeads.removeAll()
                requestWorldRefresh()
            case let .reloadMessages(id):
                if pendingHistory.count < 1024 {
                    pendingHistory.insert(id)
                    requestHistoryRefresh()
                } else {
                    // Refuse overload explicitly instead of silently losing
                    // reconciliation work or retaining an unbounded queue.
                    await quarantine(.storage)
                }
            case .announceArrival, .withdrawAnnouncements: break
            }
        }
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
                do {
                    _ = try await fetchWorld(backend: backend, epoch: epoch)
                } catch {
                    await reconciliationFailed(error)
                }
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
                do {
                    _ = try await fetchMessages(in: id, before: nil, backend: backend, epoch: currentEpoch)
                } catch {
                    await reconciliationFailed(error)
                }
            }
        }
    }

    func reconciliationFailed(_ error: any Error) async {
        guard !Task.isCancelled, !stopped, !quarantinedForSubscription else { return }
        if error as? ChatError == .sessionExpired {
            await quarantine(.authentication)
        } else {
            do { try appendAndPublish(
                .backendError(.transport("Account refresh could not complete.")),
                live: false
            ) } catch { await quarantine(.storage) }
        }
    }
}
