import ChatKit
import Foundation

/// What the Calls list shows: `ChatSessionModel.callHistory`, the model's one
/// property for it. A view over call records the account already keeps, read
/// a page at a time through the backend (`SyncEngine.callHistory`), never a
/// complete provider call log. Set only by the model.
public struct CallHistorySessionState: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Nothing asked for yet.
        case idle
        /// The first page is on its way.
        case loading
        case loaded
        /// The first page could not be read; the list is empty until a retry.
        case failed
    }

    /// How many records a page asks for.
    static let pageSize = 50

    /// Whether the sidebar's Calls row is chosen. No conversation is selected then.
    public internal(set) var showingList = false
    /// Newest first, in the order the backend returned them, pages appended.
    public internal(set) var calls: [Message] = []
    public internal(set) var status = Status.idle
    /// Whether a later page is on its way.
    public internal(set) var isLoadingMore = false
    /// Whether the last later page could not be read. The rows already listed stay.
    public internal(set) var loadMoreFailed = false
    /// The backend's opaque cursor for the next page, kept verbatim; `nil`
    /// once the last page has arrived.
    var nextCursor: String?
    var work = CallHistoryWork()

    public var hasMore: Bool {
        nextCursor != nil
    }

    public init() {}

    /// Leaves the list and forgets whatever it was waiting for; the rows stay
    /// until the next first page replaces them.
    mutating func leave() {
        showingList = false
        work.cancel()
        isLoadingMore = false
    }

    mutating func apply(_ page: CallHistoryPage, appending: Bool) {
        calls = appending ? calls + page.messages : page.messages
        nextCursor = page.nextCursor
        status = .loaded
        isLoadingMore = false
        loadMoreFailed = false
    }

    mutating func fail(appending: Bool) {
        if appending {
            isLoadingMore = false
            loadMoreFailed = true
        } else {
            calls = []
            nextCursor = nil
            status = .failed
        }
    }
}

/// The page in flight, and the generation a late answer is checked against.
struct CallHistoryWork: Sendable, Equatable {
    var generation = 0
    var task: Task<Void, Never>?

    mutating func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
