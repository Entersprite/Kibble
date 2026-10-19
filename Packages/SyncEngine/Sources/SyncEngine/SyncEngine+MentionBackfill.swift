import ChatKit
import ChatPersistence
import Foundation

/// The provider's newest activity hints, not a fingerprint of message content.
/// Used only to avoid repeating background Mentions discovery. Explicit
/// foreground history and reaction refreshes still reconcile message content.
struct MentionBackfillHead: Equatable, Sendable {
    let activity: Date?
    let latestMessage: Date?

    init(_ conversation: Conversation) {
        activity = conversation.lastActivity
        latestMessage = conversation.latestMainMessageAt
    }
}

extension SyncEngine {
    /// Discovers mentions only for new or changed heads and failed pages.
    /// A real gap forces a complete sweep because missed events cannot be
    /// inferred from head hints. Successful heads are scoped to this session.
    func startMentionBackfill(force: Bool = false) {
        guard backend.capabilities.needsMentionBackfill, let mentionClock, !Task.isCancelled else { return }
        let eligible: [Conversation.ID: MentionBackfillHead]
        let candidates: [Conversation.ID]
        do {
            let conversations = try store.conversations()
            let ordered = MentionBackfill.candidates(in: conversations, now: mentionClock())
            let heads = Dictionary(uniqueKeysWithValues: conversations
                .map { ($0.id, MentionBackfillHead($0)) })
            eligible = Dictionary(uniqueKeysWithValues: ordered.compactMap { id in
                heads[id].map { (id, $0) }
            })
            if force {
                mentionBackfillHeads = [:]
            }
            mentionBackfillHeads = mentionBackfillHeads.filter { eligible[$0.key] != nil }
            candidates = ordered.filter { mentionBackfillHeads[$0] != eligible[$0] }
        } catch {
            record(error)
            return
        }
        if !force, mentionBackfillTask != nil,
           candidates.allSatisfy({ mentionBackfillCandidates[$0] == eligible[$0] }),
           mentionBackfillCandidates.allSatisfy({ eligible[$0.key] == $0.value }) {
            return
        }
        mentionBackfillTask?.cancel()
        mentionBackfillTask = nil
        mentionBackfillGeneration += 1
        let generation = mentionBackfillGeneration
        mentionBackfillCandidates = Dictionary(uniqueKeysWithValues: candidates.compactMap { id in
            eligible[id].map { (id, $0) }
        })
        writeMentionBackfill(MentionBackfillStatus(running: !candidates.isEmpty))
        guard !candidates.isEmpty else { return }
        mentionBackfillTask = Task { [weak self] in
            await self?.runMentionBackfill(over: candidates, heads: eligible, generation: generation)
        }
    }

    /// Failures remain eligible for the next world load, with no retry loop
    /// or session banner. At most three fetches are in flight within a run.
    private func runMentionBackfill(
        over candidates: [Conversation.ID], heads: [Conversation.ID: MentionBackfillHead], generation: Int
    ) async {
        let failed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            var pending = candidates[...]
            var failed = 0
            for _ in 0 ..< MentionBackfill.maxInFlight {
                guard let next = pending.popFirst() else { break }
                _ = group.addTaskUnlessCancelled {
                    await self.loadedNewestPage(of: next, head: heads[next], generation: generation)
                }
            }
            for await loaded in group {
                if !loaded {
                    failed += 1
                }
                if let next = pending.popFirst() {
                    _ = group.addTaskUnlessCancelled {
                        await self.loadedNewestPage(of: next, head: heads[next], generation: generation)
                    }
                }
            }
            return failed
        }
        guard !Task.isCancelled, generation == mentionBackfillGeneration else { return }
        mentionBackfillTask = nil
        mentionBackfillCandidates = [:]
        writeMentionBackfill(MentionBackfillStatus(running: false, failedConversations: failed))
    }

    private func loadedNewestPage(
        of conversation: Conversation.ID, head: MentionBackfillHead?, generation: Int
    ) async -> Bool {
        do {
            let version = conversationVersions[conversation, default: 0]
            try await loadMoreMessages(in: conversation)
            guard !Task.isCancelled, generation == mentionBackfillGeneration,
                  version == conversationVersions[conversation, default: 0] else { return false }
            mentionBackfillHeads[conversation] = head
            return true
        } catch {
            return false
        }
    }

    private func writeMentionBackfill(_ status: MentionBackfillStatus) {
        do {
            try store.apply([.setMentionBackfill(status)])
        } catch {
            record(error)
        }
    }
}
