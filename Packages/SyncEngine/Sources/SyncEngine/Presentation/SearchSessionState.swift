import ChatKit
import ChatPersistence
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
    /// The last "more" page failed: the list offers a retry rather than
    /// asking again on its own, which would loop while the wire is down.
    public internal(set) var loadMoreFailed = false
    public internal(set) var failed = false
    public internal(set) var recents: [String] = []
    /// The hit the overlay selects when it opens again: the one being read.
    public internal(set) var focus: Message.ID?
    /// One more every time `focus` is restamped from the bar (`showSearch()`):
    /// the overlay's own signal to reselect it, so pressing ⌘F again at the
    /// same bar position reselects the same hit too. Never achieved by
    /// clearing `focus` to `nil` first, which would flash the selection.
    public internal(set) var focusGeneration = 0
    public internal(set) var bar: SearchBarState?
    /// The message the transcript marks once, after a hit opened.
    public internal(set) var highlight: Message.ID?
    /// One more on every hit that opens, written with `highlight`, so opening
    /// the hit already scrolled to and marked scrolls and marks it again.
    public internal(set) var openGeneration = 0

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
    /// Why the hit could not be reached; `nil` while it can be.
    public internal(set) var unreachable: Unreachable?
    /// The page past the last loaded hit failed: the bar offers a retry
    /// rather than asking again on its own, which would loop while the wire
    /// is down. Cleared the moment the next step asks again, not when that
    /// page lands.
    public internal(set) var pageFailed = false

    public enum Unreachable: Equatable, Sendable {
        /// It could not be stored to open: the store refused it, and the
        /// failure is recorded where errors show, or lost it before the open
        /// read it back. Not "history ran out": a hit is stored as search
        /// found it, however far back it is
        /// (`SyncEngine.loadHistory(in:until:pageLimit:)`).
        case tooFarBack
        /// Its conversation is not in the sidebar.
        case notInSidebar
    }
}

/// The search's tasks and timings. Not observed.
struct SearchWork {
    let debounce: Duration
    let historyPageLimit: Int
    var task: Task<Void, Never>?
    var peopleTask: Task<Void, Never>?
    /// The list's "more" page.
    var pageTask: Task<Void, Never>?
    /// The bar's next page, apart from the list's so neither cancels the other.
    var barPageTask: Task<Void, Never>?
    var openTask: Task<Void, Never>?
    var recentsTask: Task<Void, Never>?
    /// Saving an opened search as a recent.
    var recordTask: Task<Void, Never>?
    /// The query whose request is on the wire, so Return does not send it
    /// twice.
    var inFlight: MessageSearchQuery?

    init(debounce: Duration, historyPageLimit: Int) {
        self.debounce = debounce
        self.historyPageLimit = historyPageLimit
    }

    mutating func reset() {
        for task in [task, peopleTask, pageTask, barPageTask, openTask, recentsTask, recordTask] {
            task?.cancel()
        }
        task = nil
        peopleTask = nil
        pageTask = nil
        barPageTask = nil
        openTask = nil
        recentsTask = nil
        recordTask = nil
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
