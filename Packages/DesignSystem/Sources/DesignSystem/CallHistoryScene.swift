import ChatKit
import SwiftUI

/// One row of the Calls list. Values only: the mapping from a retained call
/// record is this initialiser, pure, and tested. A record is history: nothing
/// here says whether a call is still going on.
public struct CallHistoryItem: Identifiable, Sendable, Equatable {
    public let id: Message.ID
    public let conversationID: Conversation.ID
    /// For the row's picture; `nil` when the conversation is no longer listed.
    public let conversation: Conversation?
    public let conversationTitle: String
    public let status: MessageCallStatus
    /// Who posted the record, "You" for yourself.
    public let senderName: String
    public let createdAt: Date

    public init(
        message: Message, conversation: Conversation?, directory: [Member.ID: Member], me: Member.ID?
    ) {
        id = message.id
        conversationID = message.conversationID
        self.conversation = conversation
        conversationTitle = conversation
            .map { Display.title(of: $0, directory: directory, me: me) } ?? CallHistoryPresentation
            .unlistedTitle
        status = message.callStatus ?? .unknown("")
        senderName = message.sender == me ? "You" : Display.name(of: message.sender, in: directory)
        createdAt = message.createdAt
    }
}

/// What the Calls list shows, as the window draws it. It mirrors SyncEngine's
/// `CallHistorySessionState`, which this package cannot see.
public struct CallHistoryScene: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case idle, loading, loaded, failed
    }

    /// Whether the Calls row is chosen. `selected` is then `nil`.
    public var showingList: Bool
    public var items: [CallHistoryItem]
    public var status: Status
    /// Whether the backend has a later page.
    public var hasMore: Bool
    public var isLoadingMore: Bool
    public var loadMoreFailed: Bool

    public init(
        showingList: Bool = false, items: [CallHistoryItem] = [], status: Status = .idle,
        hasMore: Bool = false, isLoadingMore: Bool = false, loadMoreFailed: Bool = false
    ) {
        self.showingList = showingList
        self.items = items
        self.status = status
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.loadMoreFailed = loadMoreFailed
    }
}

/// The Calls list's callbacks, from the host that reads the records.
@MainActor
public struct CallHistoryActions {
    public var show: () -> Void
    /// Asks for the next page; the host ignores it while one is on its way
    /// or none is left.
    public var loadMore: () -> Void
    /// Reads the first page again, after it failed.
    public var retry: () -> Void
    /// Opens the record's conversation at the record, as a mention opens.
    public var open: (Conversation.ID, Message.ID) -> Void

    public init(
        show: @escaping () -> Void,
        loadMore: @escaping () -> Void,
        retry: @escaping () -> Void,
        open: @escaping (Conversation.ID, Message.ID) -> Void
    ) {
        self.show = show
        self.loadMore = loadMore
        self.retry = retry
        self.open = open
    }
}

/// What the row and the pane say. Pure, so every state is a test.
public enum CallHistoryPresentation {
    public enum Content: Equatable, Sendable {
        case loading
        case empty
        case failed
        case items
    }

    public static let title = "Calls"
    /// Verified with `NSImage(systemSymbolName:accessibilityDescription:)`
    /// (`CallHistoryPresentationTests`).
    public static let rowSymbol = "phone"
    static let loadingText = "Loading Calls…"
    static let emptyTitle = "No Calls"
    static let emptyText = "Calls in this account’s conversations appear here."
    static let failedTitle = "Couldn’t Load Calls"
    static let failedText = "The call list couldn’t be read right now."
    static let loadMoreFailedText = "Couldn’t load more calls."
    static let retryTitle = "Try Again"
    /// The list's honest scope: what this account keeps, not every call
    /// ever made.
    static let coverageText = "Calls saved in this account’s conversations."
    /// The context menu's item, which does what Return and a double-click do.
    static let openTitle = "Show in Conversation"
    static let callBackTitle = "Call Back"
    static let unlistedTitle = "Conversation"

    /// Rows show as soon as there are any; the overlay speaks only for an
    /// empty list.
    public static func content(_ scene: CallHistoryScene) -> Content {
        if !scene.items.isEmpty {
            return .items
        }
        switch scene.status {
        case .idle, .loading: return .loading
        case .loaded: return .empty
        case .failed: return .failed
        }
    }

    /// The card's own words, so a record reads the same in both places.
    public static func statusTitle(_ status: MessageCallStatus) -> String {
        CallMessageCard.title(of: status)
    }

    /// What VoiceOver reads for a row.
    static func spoken(_ item: CallHistoryItem, now: Date) -> String {
        [
            item.conversationTitle, statusTitle(item.status), item.senderName,
            Display.timestamp(of: item.createdAt, now: now)
        ].joined(separator: ", ")
    }
}
