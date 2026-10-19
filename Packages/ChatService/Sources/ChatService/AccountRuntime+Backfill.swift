import ChatKit
import ChatRules
import Foundation

extension AccountRuntime {
    func requestBackfill(replay: Bool = false) {
        guard !stopped, !quarantinedForSubscription else { return }
        backfillRequested = true
        backfillReplayRequested = backfillReplayRequested || replay
        guard backfill == nil else { return }
        backfill = Task {
            defer { backfill = nil }
            while backfillRequested, !stopped, !Task.isCancelled {
                backfillRequested = false
                let replay = backfillReplayRequested
                backfillReplayRequested = false
                guard let backend else { return }
                let epoch = currentEpoch
                if backend.capabilities.needsFollowedThreadsBackfill {
                    do {
                        _ = try await fetchFollowedThreads(backend: backend, epoch: epoch)
                    } catch {
                        await reconciliationFailed(error)
                    }
                }
                guard backend.capabilities.needsMentionBackfill, !Task.isCancelled, !stopped else { continue }
                await backfillMentions(backend: backend, epoch: epoch, replay: replay)
            }
        }
    }

    private func backfillMentions(backend: any ChatBackend, epoch: UUID, replay: Bool) async {
        do {
            let rows = try storage.conversations()
            let eligible = MentionBackfill.candidates(in: rows, now: now())
            let heads = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, MentionBackfillHead($0)) })
            backfillHeads = backfillHeads.filter { heads[$0.key] == $0.value }
            let candidates = eligible.filter { replay || backfillHeads[$0] != heads[$0] }
            try appendAndPublish(.mentionBackfillChanged(.init(running: !candidates.isEmpty)), live: false)
            let failures = await withTaskGroup(of: Int.self) { group in
                var pending = candidates.makeIterator()
                for _ in 0 ..< MentionBackfill.maxInFlight {
                    guard let id = pending.next() else { break }
                    group.addTask { await self.backfillHistory(
                        id,
                        head: heads[id],
                        backend: backend,
                        epoch: epoch
                    ) }
                }
                var failures = 0
                for await failed in group {
                    failures += failed
                    if !Task.isCancelled, let id = pending.next() {
                        group.addTask { await self.backfillHistory(
                            id,
                            head: heads[id],
                            backend: backend,
                            epoch: epoch
                        ) }
                    }
                }
                return failures
            }
            try checkEpoch(epoch)
            try appendAndPublish(.mentionBackfillChanged(.init(failedConversations: failures)), live: false)
        } catch { await reconciliationFailed(error) }
    }

    private func backfillHistory(
        _ id: Conversation.ID, head: MentionBackfillHead?, backend: any ChatBackend, epoch: UUID
    ) async -> Int {
        do {
            try checkEpoch(epoch)
            if backfillHeads[id] == head {
                let cached = try storage.recentHistory(in: id, limit: 200)
                try appendAndPublish(
                    .historyLoaded(MessageHistoryUpdate(messages: cached, conversationID: id)),
                    live: false
                )
            } else {
                _ = try await fetchMessages(in: id, before: nil, backend: backend, epoch: epoch)
            }
            try checkEpoch(epoch)
            if backfillHeads.count >= 4096,
               let oldest = backfillHeads.keys.first {
                backfillHeads[oldest] = nil
            }
            backfillHeads[id] = head
            return 0
        } catch {
            if error as? ChatError == .sessionExpired {
                await quarantine(.authentication)
            }
            return 1
        }
    }
}
