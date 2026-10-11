import ChatKit
import Foundation

/// Everything the window draws of a search (search spec §1, §3). One value,
/// set in one mutation per change: a struct on an `@Observable` model
/// invalidates every reader on any field's write (CLAUDE.md, session 61).
public struct SearchSessionState: Equatable, Sendable {
    public internal(set) var isShown = false
    public internal(set) var query = MessageSearchQuery()
    /// Conversations whose name matches, from the store: instant.
    public internal(set) var conversations: [Conversation] = []
    /// People whose name matches: known first, then the directory's.
    public internal(set) var people: [Member] = []
    public internal(set) var hits: [Message] = []
    public internal(set) var next: MessageSearchCursor?
    /// The query `hits` answers; `nil` before an answer.
    public internal(set) var answered: MessageSearchQuery?
    public internal(set) var isSearching = false
    public internal(set) var isLoadingMore = false
    public internal(set) var failed = false
    public internal(set) var recents: [String] = []
    /// The hit the overlay selects when it opens again: the one being read.
    public internal(set) var focus: Message.ID?
    public internal(set) var bar: SearchBarState?
    /// The message the transcript marks once, after a hit opened.
    public internal(set) var highlight: Message.ID?

    public init() {}
}

/// The results bar (search spec §1.4): the hits a search opened from, and
/// which one is open.
public struct SearchBarState: Equatable, Sendable {
    public internal(set) var query: MessageSearchQuery
    public internal(set) var hits: [Message]
    public internal(set) var next: MessageSearchCursor?
    public internal(set) var index: Int
    /// History is being paged back to reach the hit.
    public internal(set) var isOpening = false
    /// The hit could not be reached: too far back, or in a conversation the
    /// sidebar does not have.
    public internal(set) var unreachable = false
}

/// The search's tasks and timings. Not observed.
struct SearchWork {
    let debounce: Duration
    let historyPageLimit: Int
    var task: Task<Void, Never>?
    var peopleTask: Task<Void, Never>?
    var pageTask: Task<Void, Never>?
    var openTask: Task<Void, Never>?
    /// The query whose request is on the wire, so Return does not send it
    /// twice (Review Focus 1).
    var inFlight: MessageSearchQuery?

    init(debounce: Duration, historyPageLimit: Int) {
        self.debounce = debounce
        self.historyPageLimit = historyPageLimit
    }

    mutating func reset() {
        for task in [task, peopleTask, pageTask, openTask] {
            task?.cancel()
        }
        task = nil
        peopleTask = nil
        pageTask = nil
        openTask = nil
        inFlight = nil
    }
}

/// Words, for matching names: folded, split on spaces.
enum SearchWords {
    static func of(_ text: String) -> [String] {
        folded(text).split(separator: " ").map(String.init)
    }

    static func match(_ name: String, _ words: [String]) -> Bool {
        let name = folded(name)
        return !words.isEmpty && words.allSatisfy { name.contains($0) }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
