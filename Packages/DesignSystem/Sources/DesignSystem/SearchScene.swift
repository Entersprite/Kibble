import ChatKit
import Foundation

/// Everything the window draws about a search (search spec §1), one value on
/// `ChatSceneState`.
public struct SearchSceneState: Sendable, Equatable {
    public var isShown: Bool
    public var query: MessageSearchQuery
    public var conversations: [Conversation]
    public var people: [Member]
    public var hits: [Message]
    public var isSearching: Bool
    public var isLoadingMore: Bool
    /// The last "more" page failed: a retry row instead of the trigger.
    public var loadMoreFailed: Bool
    public var hasMore: Bool
    public var failed: Bool
    public var recents: [String]
    /// The hit to select when the overlay opens.
    public var focus: Message.ID?
    /// One more every time `focus` is restamped, even to the same value: what
    /// the overlay watches to reselect it on ⌘F back to the same bar position.
    public var focusGeneration: Int
    public var bar: SearchBarScene?

    public init(
        isShown: Bool = false, query: MessageSearchQuery = MessageSearchQuery(),
        conversations: [Conversation] = [], people: [Member] = [], hits: [Message] = [],
        isSearching: Bool = false, isLoadingMore: Bool = false, loadMoreFailed: Bool = false,
        hasMore: Bool = false,
        failed: Bool = false, recents: [String] = [], focus: Message.ID? = nil, focusGeneration: Int = 0,
        bar: SearchBarScene? = nil
    ) {
        self.isShown = isShown
        self.query = query
        self.conversations = conversations
        self.people = people
        self.hits = hits
        self.isSearching = isSearching
        self.isLoadingMore = isLoadingMore
        self.loadMoreFailed = loadMoreFailed
        self.hasMore = hasMore
        self.failed = failed
        self.recents = recents
        self.focus = focus
        self.focusGeneration = focusGeneration
        self.bar = bar
    }
}

/// The results bar's content (search spec §1.4).
public struct SearchBarScene: Sendable, Equatable {
    public var query: MessageSearchQuery
    public var index: Int
    public var count: Int
    public var hasMore: Bool
    public var isOpening: Bool
    /// Why the hit could not be opened; `nil` while it can be.
    public var unreachable: Unreachable?
    /// The page past the last loaded hit failed to load.
    public var pageFailed: Bool

    public enum Unreachable: Sendable, Equatable {
        /// The hit could not be kept to open, however near or far back it is;
        /// a failure behind it shows in the error banner.
        case tooFarBack
        case notInSidebar
    }

    public init(
        query: MessageSearchQuery, index: Int, count: Int, hasMore: Bool = false,
        isOpening: Bool = false, unreachable: Unreachable? = nil, pageFailed: Bool = false
    ) {
        self.query = query
        self.index = index
        self.count = count
        self.hasMore = hasMore
        self.isOpening = isOpening
        self.unreachable = unreachable
        self.pageFailed = pageFailed
    }
}

/// What the window can ask of a search. **Optional on `ChatSceneActions`, and
/// `nil` is the point**: a backend that cannot search gets no overlay.
@MainActor
public struct SearchActions {
    public var show: () -> Void
    public var hide: () -> Void
    public var textChanged: (String) -> Void
    public var setQuery: (MessageSearchQuery) -> Void
    public var submit: () -> Void
    public var loadMore: () -> Void
    public var openConversation: (Conversation.ID) -> Void
    public var openPerson: (Member.ID) -> Void
    public var openMessage: (Message.ID) -> Void
    public var step: (Int) -> Void
    public var end: () -> Void

    public init(
        show: @escaping () -> Void, hide: @escaping () -> Void, textChanged: @escaping (String) -> Void,
        setQuery: @escaping (MessageSearchQuery) -> Void, submit: @escaping () -> Void,
        loadMore: @escaping () -> Void, openConversation: @escaping (Conversation.ID) -> Void,
        openPerson: @escaping (Member.ID) -> Void, openMessage: @escaping (Message.ID) -> Void,
        step: @escaping (Int) -> Void, end: @escaping () -> Void
    ) {
        self.show = show
        self.hide = hide
        self.textChanged = textChanged
        self.setQuery = setQuery
        self.submit = submit
        self.loadMore = loadMore
        self.openConversation = openConversation
        self.openPerson = openPerson
        self.openMessage = openMessage
        self.step = step
        self.end = end
    }
}
