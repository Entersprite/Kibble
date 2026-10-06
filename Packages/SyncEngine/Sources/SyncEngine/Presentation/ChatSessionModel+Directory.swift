import ChatKit
import Foundation

/// What the directory search and the membership checks keep between calls.
/// One stored property on `ChatSessionModel`, for that file's length.
struct DirectorySearchState {
    let debounce: Duration
    let membershipWait: Duration
    var task: Task<Void, Never>?
    /// One check per person per conversation per session, kept so a later
    /// `nonMembers` can wait for it.
    var checks: [Conversation.ID: [Member.ID: Task<ConversationMembership, Never>]] = [:]

    init(debounce: Duration, membershipWait: Duration) {
        self.debounce = debounce
        self.membershipWait = membershipWait
    }

    mutating func reset() {
        task?.cancel()
        task = nil
        checks = [:]
    }
}

/// The `@` list's directory section and the membership checks behind the
/// add-or-not confirmation (mention non-members spec §3.4).
public extension ChatSessionModel {
    /// The composer's active `@` query, or `nil` when there is none.
    /// Debounced; a newer query cancels an older one, and only the newest
    /// query's answer is published. Spaces only. A failure clears the
    /// results and records nothing: the directory section is a convenience.
    func directoryQuery(_ query: String?) {
        directorySearch.task?.cancel()
        guard let query, !query.isEmpty, capabilities.canMentionNonMembers, let selected,
              conversations.first(where: { $0.id == selected })?.kind == .space
        else {
            directoryResults = []
            return
        }
        let debounce = directorySearch.debounce
        directorySearch.task = Task { @MainActor [weak self, engine] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
            let found = await (try? engine.searchPeople(query)) ?? []
            // A newer query cancelled this one while it was out: its answer
            // must not replace the newer one's (review focus 2).
            guard !Task.isCancelled, let self else { return }
            directoryResults = found.filter { $0.id != me }
        }
    }

    /// Asked for a person picked from the directory section: once per person
    /// per conversation per session.
    func checkMembership(_ member: Member.ID) {
        guard let selected, directorySearch.checks[selected]?[member] == nil else { return }
        directorySearch.checks[selected, default: [:]][member] = Task { [engine] in
            await (try? engine.membership(of: member, in: selected)) ?? .unknown
        }
    }

    /// The mentioned people a check says are not members, or could not tell,
    /// waiting up to the membership wait for checks still running. A person
    /// with no check was picked from the members section, and is a member.
    func nonMembers(in message: ComposedMessage) async -> [Member.ID] {
        guard let selected else { return [] }
        let checks = directorySearch.checks[selected] ?? [:]
        let wait = directorySearch.membershipWait
        // A member now is a member, whatever an earlier check said: after "Add
        // and send" they join the members section (review finding 3).
        let members = Set(mentionCandidates.map(\.id))
        var result: [Member.ID] = []
        for mention in message.mentions {
            guard case let .user(id) = mention.target, !members.contains(id), let check = checks[id],
                  !result.contains(id)
            else { continue }
            if await Self.answer(of: check, within: wait) != .member {
                result.append(id)
            }
        }
        return result
    }

    /// The check's answer, or `.unknown` once `wait` has passed, whichever
    /// comes first. Not a task group: a group waits for every child, so a
    /// check that never answers would hold the timeout hostage.
    private static func answer(
        of check: Task<ConversationMembership, Never>,
        within wait: Duration
    ) async -> ConversationMembership {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { await once.resume(check.value) }
            Task {
                try? await Task.sleep(for: wait)
                await once.resume(.unknown)
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever caller arrives first.
private actor ResumeOnce {
    private var continuation: CheckedContinuation<ConversationMembership, Never>?

    init(_ continuation: CheckedContinuation<ConversationMembership, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: ConversationMembership) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
