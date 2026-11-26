import ChatKit
import Foundation
import Observation

@MainActor
@Observable
public final class ScheduledMessagesSessionState {
    public struct Receipt: Equatable, Sendable {
        public let id: UUID
        public let body: ComposedMessage
    }

    public internal(set) var showingList = false
    public internal(set) var messages: [ScheduledMessage] = []
    public internal(set) var isLoading = false
    public internal(set) var readFailed = false
    public internal(set) var pending: Set<ScheduledMessageAddress> = []
    public internal(set) var submissions: Set<MessageAddress> = []
    public internal(set) var receipts: [MessageAddress: Receipt] = [:]
    var cursor: String?
    @ObservationIgnored var loadID = UUID()
    @ObservationIgnored var load: Task<Void, Never>?
    @ObservationIgnored var refreshAfterLoad = false
    @ObservationIgnored var writes: [ScheduledMessageAddress: Task<Void, Never>] = [:]
    @ObservationIgnored var creates: [MessageAddress: Task<Void, Never>] = [:]

    public var hasMore: Bool {
        cursor != nil
    }

    func cancelLoad() {
        loadID = UUID()
        load?.cancel()
        load = nil
        isLoading = false
        refreshAfterLoad = false
    }

    func leave() {
        showingList = false
        cancelLoad()
    }

    func stop() {
        leave()
        writes.values.forEach { $0.cancel() }
        creates.values.forEach { $0.cancel() }
        writes = [:]
        creates = [:]
        messages = []
        pending = []
        submissions = []
        receipts = [:]
        cursor = nil
        readFailed = false
    }
}
