import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    /// Refresh from committed service data, independently of client selection
    /// or replicas. One account-owned worker coalesces directory deliveries.
    func callDirectoryChanged(by event: ChatEvent) {
        switch event {
        case .conversationsChanged, .conversationUpdated, .conversationClassified,
             .conversationRemoved, .membersChanged, .membersResolved:
            requestCallDirectoryRefresh()
        default: break
        }
    }

    func requestCallDirectoryRefresh() {
        guard !calls.isEmpty, !stopped, !quarantinedForSubscription else { return }
        callDirectoryDirty = true
        guard callDirectoryRefresh == nil else { return }
        callDirectoryRefresh = Task {
            defer { callDirectoryRefresh = nil }
            while callDirectoryDirty, !stopped, !quarantinedForSubscription, !Task.isCancelled {
                callDirectoryDirty = false
                do {
                    let recipients = try canonicalCallRecipients()
                    let epoch = currentEpoch
                    for source in calls.values {
                        guard epoch == currentEpoch, !stopped, !quarantinedForSubscription,
                              !Task.isCancelled else { return }
                        await source.updateRecipients(recipients)
                    }
                } catch {
                    await quarantine(.storage)
                    return
                }
            }
        }
    }

    private func canonicalCallRecipients() throws -> [AudioCallRecipient] {
        // The existing replacement-snapshot read is atomic and excludes history.
        guard let events = try storage.readEvents(after: nil, limit: 1).snapshot else {
            throw ServiceFailure.invalidResponse
        }
        var conversations: [Conversation] = []
        var members: [Member.ID: Member] = [:]
        for event in events {
            switch event {
            case let .conversationsChanged(rows): conversations = rows
            case let .membersResolved(rows):
                for member in rows {
                    members[member.id] = member
                }
            default: break
            }
        }
        return AudioCallRecipient.directory(conversations: conversations, members: members, me: record.selfID)
    }
}
