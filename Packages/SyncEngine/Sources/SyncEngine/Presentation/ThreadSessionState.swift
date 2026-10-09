import ChatKit
import Foundation

/// What the thread panel and the Threads list show (threads spec §4.3):
/// `ChatSessionModel.threads`, the model's one property for threads.
///
/// Fed like the rest of the model, by observations on the store: the open
/// thread's messages, the selected conversation's summaries, the followed
/// threads and their badge. Never read during a render (CLAUDE.md, session
/// 46). Set only by the model.
public struct ThreadSessionState: Sendable, Equatable {
    /// How many followed threads the list shows at most.
    static let listLimit = 50

    /// The thread the panel shows, always one of the selected conversation's;
    /// `nil` while the panel is closed.
    public internal(set) var openThread: MessageThread.ID?
    /// The open thread's messages, its first message included, oldest first.
    public internal(set) var messages: [Message] = []
    /// The selected conversation's threads, for the marks under its bubbles.
    public internal(set) var summaries: [MessageThread.ID: MessageThread] = [:]
    /// The Threads list: followed threads, newest activity first.
    public internal(set) var followed: [FollowedThread] = []
    /// The Threads row's badge: followed threads that are unread.
    public internal(set) var unreadCount = 0
    /// Where those threads are: the sidebar shows these conversations' dots
    /// (session 58).
    public internal(set) var unreadConversations: Set<Conversation.ID> = []
    /// Whether the sidebar's Threads row is chosen. No conversation is selected then.
    public internal(set) var showingList = false
    /// The reply the panel scrolls to when a mention or a notification of a
    /// reply opened it; `nil` opens it at the newest reply.
    public internal(set) var scrollTarget: Message.ID?
    /// Whether a Follow or Unfollow is in flight. The toggle changes only when
    /// it answers (spec §5.2), and one runs at a time.
    public internal(set) var followPending = false

    /// The model's tasks and the panel's auto-mark-read bookkeeping. Here
    /// because the model has one property for threads; the cost is that
    /// installing or clearing a mark notifies whoever observes `threads`.
    var work = ThreadWork()

    public init() {}

    /// The badge and the dots in one mutation, so nothing observing `threads`
    /// sees one without the other.
    mutating func setUnread(_ unread: UnreadThreads) {
        unreadCount = unread.count
        unreadConversations = unread.conversations
    }

    /// For `ChatSessionModel.stop()`: cancels every task the panel and the
    /// list started, a mark superseded on the wire included
    /// (`ThreadWork.superseded`), for `stop()`'s own reason (nothing from the
    /// account being signed out of may answer into an erased store), and
    /// forgets the watermark. `markGeneration` stays, for the ABA its doc
    /// comment names.
    mutating func stop() {
        work.cancelAll()
        followPending = false
    }
}

// `ThreadKey` (a thread in its conversation) is Task 5's, in
// `Store/ChatStore+Threads.swift`, `Hashable, Sendable`, with a memberwise
// `init(conversation:thread:)`. It is reused here, never declared twice.

/// What `ThreadSessionState` keeps for the model alone.
///
/// `published`, `markTasks` and `markGeneration` are `ChatSessionModel`'s
/// three of the same names, per thread (`+ThreadMarkRead.swift`). Their doc
/// comments there hold here, including that `markGeneration` is never reset.
struct ThreadWork: Sendable, Equatable {
    /// The open thread's observation and its fetches, canceled when the panel
    /// closes or shows another thread.
    var panelTasks: [Task<Void, Never>] = []
    /// The Follow or Unfollow in flight.
    var followTask: Task<Void, Never>?
    /// The fetch `showThreads()` started.
    var listTask: Task<Void, Never>?
    var published: [ThreadKey: Date] = [:]
    var markTasks: [ThreadKey: Task<Void, Never>] = [:]
    var markGeneration: [ThreadKey: Int] = [:]
    /// The generation whose mark has reached `engine.submit`, per thread. From
    /// then on the mark is on the wire, and `markThreadUnread(from:)` lets it
    /// answer rather than cancel it, which would abort the request.
    var submittedGeneration: [ThreadKey: Int] = [:]
    /// Marks a Mark as Unread superseded while they were on the wire: out of
    /// `markTasks` and left to answer, but still canceled by `cancelAll()`,
    /// because at sign-out their order no longer matters and nothing may
    /// answer into an erased store. Each leaves when the unread mark waiting
    /// for it stops waiting.
    var superseded: [Task<Void, Never>] = []
    /// The thread a manual Mark as Unread turned auto-mark-read off for, until
    /// the panel closes or shows another thread (spec §4.3).
    var disarmed: ThreadKey?

    mutating func cancelAll() {
        let all = panelTasks + Array(markTasks.values) + superseded
            + [followTask, listTask].compactMap(\.self)
        for task in all {
            task.cancel()
        }
        panelTasks = []
        markTasks = [:]
        superseded = []
        followTask = nil
        listTask = nil
        published = [:]
        submittedGeneration = [:]
        disarmed = nil
    }
}
