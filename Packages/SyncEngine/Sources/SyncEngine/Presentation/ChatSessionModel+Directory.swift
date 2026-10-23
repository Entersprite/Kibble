import ChatKit
import ChatPersistence
import Foundation

/// Who in a message is outside its conversation, and how "Add and Send" can
/// add them (mention non-members spec §2).
public struct NonMembers: Equatable, Sendable {
    public enum Adding: Equatable, Sendable {
        /// The message adds them: their mentions go as `.invite`
        /// (`findings.md` §58.1, seen in a space).
        case byMention
        /// They are added first, through `ConversationMutation.addPeople`,
        /// and the message is sent only once that is confirmed.
        case beforeSending
        /// Nothing here can add them: the message can go only without adding them.
        case unavailable
    }

    public var people: [Member.ID]
    public var adding: Adding

    public init(people: [Member.ID] = [], adding: Adding = .unavailable) {
        self.people = people
        self.adding = adding
    }
}

/// What the directory search and the membership checks keep between calls.
/// One stored property on `ChatSessionModel`, for that file's length.
struct DirectorySearchState {
    let debounce: Duration
    let membershipWait: Duration
    var task: Task<Void, Never>?
    /// One check per person per conversation per session, kept so a later
    /// `nonMembers` can wait for it.
    var checks: [Conversation.ID: [Member.ID: Task<ConversationMembership, Never>]] = [:]
    /// Whether a group chat lets this account add people, read once per group
    /// chat per session from its details, at the first outside pick there.
    var addChecks: [Conversation.ID: Task<Bool, Never>] = [:]

    init(debounce: Duration, membershipWait: Duration) {
        self.debounce = debounce
        self.membershipWait = membershipWait
    }

    mutating func reset() {
        task?.cancel()
        task = nil
        for check in checks.values.flatMap(\.values) {
            check.cancel()
        }
        for check in addChecks.values {
            check.cancel()
        }
        checks = [:]
        addChecks = [:]
    }
}

/// The `@` list's directory section and the membership checks behind the
/// add-or-not confirmation (mention non-members spec §3.4), in spaces and
/// group chats. A 1:1 DM can never gain anyone, so it is never offered outsiders.
public extension ChatSessionModel {
    /// The kinds whose composers offer people outside the conversation.
    nonisolated static func offersOutsiders(in kind: Conversation.Kind) -> Bool {
        kind == .space || kind == .groupDirectMessage
    }

    /// Whether the selected conversation's composers, its thread's included,
    /// offer directory people and ask about them at Return.
    var offersOutsideMentions: Bool {
        guard capabilities.canMentionNonMembers, let selected, let kind = knownConversation(selected)?.kind
        else { return false }
        return Self.offersOutsiders(in: kind)
    }

    /// The composer's active `@` query, or `nil` when there is none.
    /// Debounced; a newer query cancels an older one, and only the newest
    /// query's answer is published, with the query it answers. A failure
    /// clears the results and records nothing: the directory section is a
    /// convenience, and the backend logs why (the local bridge, through its
    /// provider diagnostics).
    func directoryQuery(_ query: String?) {
        directorySearch.task?.cancel()
        guard let query, !query.isEmpty, offersOutsideMentions, let selected else {
            directoryResults = []
            directoryResultsQuery = nil
            return
        }
        // A group chat lists its members; none of them is outside it.
        let members = Set(knownConversation(selected)?.members ?? [])
        let debounce = directorySearch.debounce
        directorySearch.task = Task { @MainActor [weak self, engine] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
            let found: [Member]
            do {
                found = try await engine.searchPeople(query)
            } catch {
                found = []
            }
            // A newer query cancelled this one while it was out: its answer
            // must not replace the newer one's.
            guard !Task.isCancelled, let self else { return }
            directoryResults = found.filter { $0.id != me && !members.contains($0.id) }
            directoryResultsQuery = query
        }
    }

    /// Asked for a person picked from the directory section: once per person
    /// per conversation per session. In a group chat, also reads once whether
    /// this account may add people there.
    func checkMembership(_ member: Member.ID) {
        guard let selected else { return }
        if directorySearch.checks[selected]?[member] == nil {
            directorySearch.checks[selected, default: [:]][member] = Task { [engine] in
                await (try? engine.membership(of: member, in: selected)) ?? .unknown
            }
        }
        checkAdding(in: selected)
    }

    /// The mentioned people a check says are not members, or could not tell,
    /// waiting up to the membership wait for checks still running, and how
    /// they can be added. A person with no check was picked from the members
    /// section, and is a member; so is anyone the conversation lists.
    func nonMembers(in message: ComposedMessage) async -> NonMembers {
        guard let selected else { return NonMembers() }
        let checks = directorySearch.checks[selected] ?? [:]
        let wait = directorySearch.membershipWait
        // A member now is a member, whatever an earlier check said: after "Add
        // and send" they join the members section. The conversation's own list
        // counts too, though only as a yes: a group chat's can be cut short
        // (`findings.md` §37.6), so a person missing from it is still asked about.
        let members = Set(mentionCandidates.map(\.id) + (knownConversation(selected)?.members ?? []))
        var people: [Member.ID] = []
        for mention in message.mentions {
            guard case let .user(id) = mention.target, !members.contains(id), let check = checks[id],
                  !people.contains(id)
            else { continue }
            if await Self.answer(of: check, within: wait, otherwise: .unknown) != .member {
                people.append(id)
            }
        }
        guard !people.isEmpty else { return NonMembers() }
        return await NonMembers(people: people, adding: adding(in: selected, within: wait))
    }

    /// "Add and Send" where the message cannot add anyone
    /// (`NonMembers.Adding.beforeSending`): adds `people` to `conversation`,
    /// and sends `message` there, into `thread` when one is given, only once
    /// the add is confirmed for every one of them. Anything less sends
    /// nothing: the message goes back to its draft, and the failure shows
    /// where errors do. An unconfirmed add is never tried again from here.
    func addAndSend(
        _ message: ComposedMessage,
        adding people: [Member.ID],
        in conversation: Conversation.ID,
        thread: MessageThread.ID?
    ) {
        let taskID = UUID()
        sendTasks[taskID] = Task { @MainActor [weak self, engine] in
            defer { self?.sendTasks.removeValue(forKey: taskID) }
            var failure: ChatError?
            do {
                let result = try await engine.mutateConversation(
                    .addPeople(people), in: conversation, operationID: ClientOperationID.make(),
                    expectedRevision: nil
                )
                if !result.isConfirmed || !Set(result.failedMembers).isDisjoint(with: people) {
                    failure = Self.notAdded
                }
            } catch {
                failure = error as? ChatError ?? Self.notAdded
            }
            guard let self, !Task.isCancelled else { return }
            guard let failure else {
                if let thread {
                    sendReply(message, in: conversation, thread: thread)
                } else {
                    send(message, in: conversation)
                }
                return
            }
            if let thread {
                keepReplyDraft(message, in: conversation, thread: thread)
            } else {
                keepDraft(message, in: conversation)
            }
            await engine.record(failure)
        }
    }
}

extension ChatSessionModel {
    static let notAdded = ChatError.unknown("They could not be added, so the message was not sent.")

    func knownConversation(_ id: Conversation.ID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// A group chat is added to by a membership write, never by the message:
    /// `INVITE` mentions are seen only in a space (`findings.md` §58.1). The
    /// details' `addPeople` is the provider's own answer to whether this
    /// account may add anyone there.
    private func checkAdding(in id: Conversation.ID) {
        guard directorySearch.addChecks[id] == nil,
              knownConversation(id)?.kind == .groupDirectMessage else { return }
        let readable = capabilities.canReadConversationDetails
        directorySearch.addChecks[id] = Task { [engine] in
            guard readable, let details = try? await engine.loadConversationDetails(id) else { return false }
            return details.allowedActions.contains(ConversationMutation.addPeople([]).action)
        }
    }

    /// How "Add and Send" adds people in `id`: a space by the message, a group
    /// chat by a membership write when its details allow one.
    private func adding(in id: Conversation.ID, within wait: Duration) async -> NonMembers.Adding {
        switch knownConversation(id)?.kind {
        case .space?:
            return .byMention
        case .groupDirectMessage?:
            guard let check = directorySearch.addChecks[id] else { return .unavailable }
            return await Self
                .answer(of: check, within: wait, otherwise: false) ? .beforeSending : .unavailable
        default:
            return .unavailable
        }
    }

    /// The check's answer, or `otherwise` once `wait` has passed, whichever
    /// comes first. Not a task group: a group waits for every child, so a
    /// check that never answers would hold the timeout hostage.
    private static func answer<Value: Sendable>(
        of check: Task<Value, Never>,
        within wait: Duration,
        otherwise: Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { await once.resume(check.value) }
            Task {
                try? await Task.sleep(for: wait)
                await once.resume(otherwise)
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever caller arrives first.
private actor ResumeOnce<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
