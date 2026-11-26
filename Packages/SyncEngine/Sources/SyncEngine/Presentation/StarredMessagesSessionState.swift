import ChatKit
import Foundation
import Observation

@MainActor
@Observable
public final class StarredMessagesSessionState {
    public internal(set) var showingList = false
    public internal(set) var messages: [Message] = []
    public internal(set) var members: [Member.ID: Member] = [:]
    public internal(set) var knownStars: Set<MessageAddress> = []
    public internal(set) var pending: Set<MessageAddress> = []
    public internal(set) var isLoading = false
    public internal(set) var readFailed = false
    var nextCursor: String?
    @ObservationIgnored var pageCount = 0
    @ObservationIgnored var visitedCursors: Set<String> = []
    @ObservationIgnored var pageTask: Task<Void, Never>?
    @ObservationIgnored var pageID = UUID()
    @ObservationIgnored var needsRefresh = false
    @ObservationIgnored var mutations: [MessageAddress: Task<Void, Never>] = [:]

    public var hasMore: Bool {
        nextCursor != nil
    }

    func cancelPage() {
        pageID = UUID()
        pageTask?.cancel()
        pageTask = nil
        isLoading = false
        needsRefresh = false
    }

    func leave() {
        cancelPage()
        showingList = false
    }

    func stop() {
        leave()
        mutations.values.forEach { $0.cancel() }
        mutations = [:]
        messages = []
        members = [:]
        knownStars = []
        pending = []
        readFailed = false
        nextCursor = nil
        pageCount = 0
        visitedCursors = []
    }

    func accept(_ pages: [StarredMessagesPage], appending: Bool) {
        if !appending {
            messages = []
            members = [:]
            nextCursor = nil
            pageCount = 0
            visitedCursors = []
        }
        var existing = Set(messages.map(MessageAddress.init))
        for page in pages {
            if let nextCursor {
                visitedCursors.insert(nextCursor)
            }
            messages += page.messages.filter { existing.insert(MessageAddress($0)).inserted }
            for member in page.members {
                members[member.id] = member
            }
            nextCursor = page.nextCursor
        }
        pageCount += pages.count
        if nextCursor == nil {
            knownStars = existing
        } else {
            knownStars.formUnion(existing)
        }
    }

    func setKnownStar(_ starred: Bool, at address: MessageAddress) {
        if starred {
            knownStars.insert(address)
        } else {
            knownStars.remove(address)
            messages.removeAll { MessageAddress($0) == address }
        }
    }
}
