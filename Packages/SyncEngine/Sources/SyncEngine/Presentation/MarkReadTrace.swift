import ChatKit
import Foundation

// MARK: - The mark-read diagnostic instrument

/// One call's worth of evidence from the automatic mark-read trigger,
/// recorded as it happens - the same division `ChannelTraceSink` already
/// uses, and for the same reason.
///
/// **This exists to separate four hypotheses that reading the code could
/// not** (session 21's own journal): the trigger silently declining, a mark
/// that is sent but the server keeps a non-zero residual count, HTTP/queueing
/// latency, and a reconnect's `.gap(.everything)` overwriting `unreadCount`
/// out from under a mark that already succeeded. Every method here is aimed
/// at telling those apart and nothing else - it is diagnostic
/// instrumentation, not a feature, and it must never change what the trigger
/// does, only what gets written down about what it already did.
///
/// **Never message content, a conversation title, a cookie, or a token.** A
/// conformance is handed counts, durations, ages and short guard tokens only,
/// and the conversation itself is always the opaque per-session number
/// `MarkReadTraceRecorder` assigns - never the raw `Conversation.ID` and
/// never a title. The same rule `ChannelTraceSink` and `LoginTrace` already
/// keep.
public protocol MarkReadTraceSink: Sendable {
    /// Every call to `markSelectedReadIfNeeded()` - whether it declined or
    /// submitted. `record.outcome` names which of the six guards rejected it,
    /// or `.submitted` if none did.
    func triggerEvaluated(_ record: MarkReadTriggerRecord)

    /// A submitted mark has completed - accepted or not, and how long the
    /// round trip took.
    func markOutcome(_ record: MarkReadOutcomeRecord)

    /// The selected conversation's `unreadCount` changed. This is the
    /// decisive row: `5 -> 0` says the mark worked, `5 -> 1` says the server
    /// kept a residual count.
    func readStateChanged(_ record: MarkReadStateRecord)
}

/// Why `markSelectedReadIfNeeded()` declined, or that it did not - one token
/// per guard, so a decline is never ambiguous about which of the six guards
/// stopped it. Matches the six guards in
/// `ChatSessionModel+AutoMarkRead.swift`, in the order they run.
public enum MarkReadTriggerOutcome: String, Sendable, Equatable {
    case submitted
    /// `isActive` was `false` - the app is not frontmost.
    case notFrontmost = "not-frontmost"
    /// `capabilities.canMarkRead` was `false`.
    case cannotMarkRead = "cannot-mark-read"
    /// Nothing was open (`selected == nil`).
    case nothingSelected = "nothing-selected"
    /// Every loaded message was a `local/`-prefixed optimistic row, so there
    /// was no server-known position to publish.
    case noServerMessages = "no-server-messages"
    /// The newest server position was not beyond what was already published.
    case watermarkNotAdvanced = "watermark-not-advanced"
    /// A mark for this conversation was already in flight.
    case alreadyInFlight = "already-in-flight"
}

/// `MarkReadTraceSink.triggerEvaluated(_:)`'s payload.
///
/// One struct rather than the fields spelled out as parameters -
/// swiftlint's `function_parameter_count` caps a function at five, and this
/// call has more than five independent facts to report, the same reasoning
/// `UnaryCallRecord` documents for the channel trace.
public struct MarkReadTriggerRecord: Sendable {
    /// The conversation this evaluation concerned, as the opaque per-session
    /// token `MarkReadTraceRecorder` assigns - `nil` only for
    /// `.nothingSelected`, where there is no conversation to name.
    public let conversation: Int?
    public let outcome: MarkReadTriggerOutcome
    /// How many messages were loaded for the open conversation at the moment
    /// of this evaluation - `messages.count`, before the `local/` filter.
    public let loadedMessageCount: Int
    /// How many of those remain after filtering out this session's own
    /// `local/`-prefixed optimistic rows. The gap between this and
    /// `loadedMessageCount` is what tells an optimistic-only load apart from
    /// one that also holds server-confirmed messages.
    public let filteredMessageCount: Int
    /// How long ago (in seconds) the newest surviving message was created -
    /// an age, never an absolute timestamp. `nil` when no such message
    /// exists to measure.
    public let newestAgeSeconds: Double?
    /// The conversation's current `unreadCount`, read from the store at the
    /// same moment - `nil` only for `.nothingSelected`.
    public let unreadCount: Int?
    public let at: ContinuousClock.Instant

    public init(
        conversation: Int?,
        outcome: MarkReadTriggerOutcome,
        loadedMessageCount: Int,
        filteredMessageCount: Int,
        newestAgeSeconds: Double?,
        unreadCount: Int?,
        at: ContinuousClock.Instant
    ) {
        self.conversation = conversation
        self.outcome = outcome
        self.loadedMessageCount = loadedMessageCount
        self.filteredMessageCount = filteredMessageCount
        self.newestAgeSeconds = newestAgeSeconds
        self.unreadCount = unreadCount
        self.at = at
    }
}

/// `MarkReadTraceSink.markOutcome(_:)`'s payload.
public struct MarkReadOutcomeRecord: Sendable {
    public let conversation: Int
    public let accepted: Bool
    public let duration: Duration
    public let at: ContinuousClock.Instant

    public init(conversation: Int, accepted: Bool, duration: Duration, at: ContinuousClock.Instant) {
        self.conversation = conversation
        self.accepted = accepted
        self.duration = duration
        self.at = at
    }
}

/// `MarkReadTraceSink.readStateChanged(_:)`'s payload.
public struct MarkReadStateRecord: Sendable {
    public let conversation: Int
    public let unreadCount: Int
    public let at: ContinuousClock.Instant

    public init(conversation: Int, unreadCount: Int, at: ContinuousClock.Instant) {
        self.conversation = conversation
        self.unreadCount = unreadCount
        self.at = at
    }
}

/// The four `MarkReadTriggerRecord` fields that do not depend on the
/// recorder's own token table - grouped so
/// `MarkReadTraceRecorder.triggerEvaluated(conversation:outcome:context:)`
/// stays under swiftlint's `function_parameter_count` ceiling, the same
/// reasoning `UnaryCallRecord` and `MarkReadTriggerRecord` itself give.
struct MarkReadTriggerContext {
    let loadedMessageCount: Int
    let filteredMessageCount: Int
    let newestAgeSeconds: Double?
    let unreadCount: Int?
}

// MARK: - Recorder

/// Assigns each conversation a small per-session token - never the raw id -
/// and forwards trigger-evaluation, mark-outcome and read-state events to a
/// `MarkReadTraceSink`. `ChatSessionModel` holds one of these only when it was
/// asked for one (`markReadTrace:` at `init`); `nil` everywhere else, so an
/// ordinary launch never constructs this type at all.
///
/// Not itself a `ChannelTraceSink`-style protocol conformance: this is the
/// piece that has to live somewhere with stored state (the token table, the
/// selected conversation's last known count), and `ChatSessionModel+
/// AutoMarkRead.swift`'s own trigger cannot hold that state without growing
/// past `ChatSessionModel.swift`'s line budget - see this repo's own
/// `file_length` note. A plain `MainActor` class rather than an `actor`
/// because every call into it already comes from `ChatSessionModel`, which is
/// itself `@MainActor`.
@MainActor
public final class MarkReadTraceRecorder {
    private let sink: any MarkReadTraceSink
    private var tokens: [Conversation.ID: Int] = [:]
    private var nextToken = 0

    /// The conversation `conversationsChanged(_:)` should be comparing
    /// against, set by `selectionChanged(to:in:)` whenever `select(_:)` runs.
    private var selectedID: Conversation.ID?
    /// The `unreadCount` `conversationsChanged(_:)` should treat as the
    /// starting point for `selectedID` - **the count at the moment of
    /// selection, not `nil`.** Seeding this with `nil` instead (so the first
    /// post-selection observation always "establishes a baseline") looks
    /// right for opening a conversation that already shows 5 unread, but it
    /// is wrong for the one case this whole instrument exists to catch: the
    /// mark's own success is usually the *first* store write after
    /// `select(_:)` runs, so a `nil` baseline would swallow exactly the
    /// `5 -> 0` transition as "establishing a baseline" instead of reporting
    /// it. Seeding with the real count at selection time means any later
    /// write - the mark included - is compared against a real number.
    private var lastKnownUnreadCount: Int?

    public init(sink: any MarkReadTraceSink) {
        self.sink = sink
    }

    /// The opaque token for a conversation, assigned the first time it is
    /// seen and stable for the rest of this session - `findings.md`'s own
    /// rule of reporting a conversation "by index, never by id or name",
    /// applied here.
    private func token(for id: Conversation.ID) -> Int {
        if let existing = tokens[id] {
            return existing
        }
        let assigned = nextToken
        nextToken += 1
        tokens[id] = assigned
        return assigned
    }

    func triggerEvaluated(
        conversation: Conversation.ID?, outcome: MarkReadTriggerOutcome, context: MarkReadTriggerContext
    ) {
        sink.triggerEvaluated(MarkReadTriggerRecord(
            conversation: conversation.map(token(for:)),
            outcome: outcome,
            loadedMessageCount: context.loadedMessageCount,
            filteredMessageCount: context.filteredMessageCount,
            newestAgeSeconds: context.newestAgeSeconds,
            unreadCount: context.unreadCount,
            at: ContinuousClock.now
        ))
    }

    func markOutcome(conversation: Conversation.ID, accepted: Bool, duration: Duration) {
        sink.markOutcome(MarkReadOutcomeRecord(
            conversation: token(for: conversation),
            accepted: accepted,
            duration: duration,
            at: ContinuousClock.now
        ))
    }

    /// Told by `select(_:)` every time the open conversation changes -
    /// including to `nil`, which simply stops `conversationsChanged(_:)` from
    /// reporting anything until a new selection is made. `conversations` is
    /// `ChatSessionModel`'s own already-loaded list, passed in so the new
    /// baseline is the conversation's real count, not `nil` - see
    /// `lastKnownUnreadCount`'s own doc comment for why that distinction is
    /// the whole point.
    func selectionChanged(to id: Conversation.ID?, in conversations: [Conversation]) {
        selectedID = id
        lastKnownUnreadCount = id.flatMap { target in conversations.first { $0.id == target }?.unreadCount }
    }

    /// Told by the same `observeConversations()` watcher that feeds
    /// `ChatSessionModel.conversations` - diffs the selected conversation's
    /// `unreadCount` against what was last seen and reports only a change.
    func conversationsChanged(_ conversations: [Conversation]) {
        guard let selectedID, let conversation = conversations.first(where: { $0.id == selectedID }) else {
            return
        }
        defer { lastKnownUnreadCount = conversation.unreadCount }
        guard let lastKnownUnreadCount, lastKnownUnreadCount != conversation.unreadCount else {
            return
        }
        sink.readStateChanged(MarkReadStateRecord(
            conversation: token(for: selectedID),
            unreadCount: conversation.unreadCount,
            at: ContinuousClock.now
        ))
    }
}
