import ChatKit
import Foundation

/// Reusable decoded rows, validated against every complete authoritative row.
/// Reads still go through SQLite; inactive conversations need no observers and
/// edits, reactions, tombstones and optimistic replacement cannot reuse stale data.
final class DecodedTranscriptCache: @unchecked Sendable {
    private final class Entry {
        let row: MessageRow
        let message: Message
        let cost: Int
        var previous: String?
        var next: String?

        init(row: MessageRow, message: Message, cost: Int) {
            self.row = row
            self.message = message
            self.cost = cost
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var cost = 0
    private var oldest: String?
    private var newest: String?
    let budget: Int
    let entryLimit: Int

    init(budget: Int = 16 * 1024 * 1024, entryLimit: Int = 4000) {
        self.budget = budget
        self.entryLimit = entryLimit
    }

    func decode(_ row: MessageRow) throws -> Message {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[row.id], entry.row == row {
            moveToNewest(row.id, entry)
            return entry.message
        }
        let message = try row.message
        remove(row.id)
        // Account for both raw and decoded strings, collection storage and
        // allocator overhead. This is a conservative cache cost, not process RSS.
        let strings = [
            row.id,
            row.conversationID,
            row.threadID,
            row.sender,
            row.text,
            row.reactions,
            row.attachments,
            row.mentions,
            row.links,
            row.cards,
            row.localID ?? ""
        ]
        let entryCost = strings.reduce(4096) { $0 + $1.utf8.count * 4 }
        guard entryCost <= budget, entryLimit > 0 else { return message }
        while cost + entryCost > budget || entries.count >= entryLimit {
            guard let oldest else { break }
            remove(oldest)
        }
        let entry = Entry(row: row, message: message, cost: entryCost)
        entries[row.id] = entry
        cost += entryCost
        append(row.id, entry)
        return message
    }

    private func unlink(_ id: String, _ entry: Entry) {
        if let previous = entry.previous {
            entries[previous]?.next = entry.next
        } else {
            oldest = entry.next
        }
        if let next = entry.next {
            entries[next]?.previous = entry.previous
        } else {
            newest = entry.previous
        }
        entry.previous = nil
        entry.next = nil
    }

    private func append(_ id: String, _ entry: Entry) {
        entry.previous = newest
        if let newest {
            entries[newest]?.next = id
        } else {
            oldest = id
        }
        newest = id
    }

    private func moveToNewest(_ id: String, _ entry: Entry) {
        guard newest != id else { return }
        unlink(id, entry)
        append(id, entry)
    }

    private func remove(_ id: String) {
        guard let entry = entries[id] else { return }
        unlink(id, entry)
        entries.removeValue(forKey: id)
        cost -= entry.cost
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        cost = 0
        oldest = nil
        newest = nil
    }

    var retainedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func contains(_ id: Message.ID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[id.rawValue] != nil
    }
}
