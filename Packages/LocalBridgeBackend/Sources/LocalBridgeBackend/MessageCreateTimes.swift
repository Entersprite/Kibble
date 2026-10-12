import ChatKit
import Foundation

/// Each mapped message's create time in microseconds, by id: what an
/// anchored history page is built from (`findings.md` §65.9), because
/// `loadMessages(in:before:)` gets an opaque `Message.ID` and `list_topics`
/// anchors on a time.
///
/// Filled from every message this bridge maps on the way out - history
/// pages, pushes and search hits - and emptied by `disconnect()`. An id it
/// never mapped this session is unknown, and history then sends its newest
/// page, as it did before anchoring existed.
///
/// **Derived from `createdAt`, and exact.** Every mapped `createdAt` is
/// `Microseconds.date` of the wire's own microseconds, held in memory, and
/// `Microseconds.from` reads a 16-digit value back unchanged (pinned by
/// `MessageCreateTimesTests`). That would not hold for a `Date` read back
/// from a store that rounds; nothing here ever is.
///
/// **Bounded by when an id was remembered, not by its time.** Past
/// `capacity`, the least recently remembered quarter goes at once, so the
/// sort a trim costs is paid once per `capacity / 4` new ids rather than on
/// every one. Remembering an id again counts as now. An old search hit
/// remembered last is therefore the last thing to go, where evicting by
/// create time would drop the very hit about to be opened.
struct MessageCreateTimes: Sendable {
    static let defaultCapacity = 10000

    let capacity: Int
    private var entries: [ChatKit.Message.ID: Entry] = [:]
    private var nextStamp = 0

    private struct Entry: Sendable {
        let micros: Int64
        let stamp: Int
    }

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        entries.count
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    func micros(of id: ChatKit.Message.ID) -> Int64? {
        entries[id]?.micros
    }

    mutating func remember(_ messages: some Sequence<ChatKit.Message>) {
        for message in messages {
            entries[message.id] = Entry(micros: Microseconds.from(message.createdAt), stamp: nextStamp)
            nextStamp += 1
            if entries.count > capacity {
                trim()
            }
        }
    }

    mutating func forgetAll() {
        entries = [:]
    }

    /// Keeps the most recently remembered three quarters of `capacity`.
    private mutating func trim() {
        let keep = capacity - capacity / 4
        let newest = entries.sorted { $0.value.stamp > $1.value.stamp }.prefix(keep)
        entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}

extension LocalBridgeBackend {
    /// The messages a pushed event carries, for `messageTimes`: the same two
    /// cases `memberIDs(in:)` reads a sender from.
    static func messages(in event: ChatEvent) -> [ChatKit.Message] {
        switch event {
        case let .messageReceived(message), let .messageUpdated(message):
            [message]
        default:
            []
        }
    }
}
