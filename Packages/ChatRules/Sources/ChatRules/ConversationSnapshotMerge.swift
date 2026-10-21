import ChatKit

public extension ConversationSnapshot {
    /// Keep changes committed while the read was pending, including explicit removals.
    func merging(current: [Conversation], baseline: [Conversation]) -> [Conversation] {
        let latest = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let before = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        let received = Set(conversations.map(\.id))
        var merged = isComplete ? [:] : latest
        for row in conversations where !removedIDs.contains(row.id) {
            if before[row.id] != nil, latest[row.id] == nil {
                continue
            }
            if let current = latest[row.id] {
                merged[row.id] = merge(row, current: current, baseline: before[row.id])
            } else {
                merged[row.id] = row
            }
        }
        for row in current where !received.contains(row.id) && before[row.id] != row {
            merged[row.id] = row
        }
        for id in removedIDs where latest[id] == before[id] {
            merged[id] = nil
        }
        return merged.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func merge(_ row: Conversation, current: Conversation, baseline: Conversation?) -> Conversation {
        guard let baseline else { return current }
        var value = row
        func preserve(_ key: WritableKeyPath<Conversation, some Equatable>) {
            if current[keyPath: key] != baseline[keyPath: key] {
                value[keyPath: key] = current[keyPath: key]
            }
        }
        preserve(\.kind); preserve(\.title); preserve(\.avatarURL); preserve(\.meeting)
        preserve(\.lastActivity); preserve(\.latestMainMessageAt)
        preserve(\.unreadCount); preserve(\.hasUnread); preserve(\.readPosition)
        preserve(\.isMuted); preserve(\.notificationLevel); preserve(\.markedUnreadAt)
        preserve(\.members); preserve(\.memberCount); preserve(\.isThreaded)
        preserve(\.repliesEnabled); preserve(\.hasUnreadThread); preserve(\.historyClearedBefore)
        // A read or Mark as unread changes the whole read-state snapshot,
        // even when the count itself equals the value at request start.
        if current.readPosition != baseline.readPosition || current.markedUnreadAt != baseline
            .markedUnreadAt {
            value.unreadCount = current.unreadCount
            value.hasUnread = current.hasUnread
        }
        if preservesDetails {
            value.title = value.title ?? current.title
            value.avatarURL = value.avatarURL ?? current.avatarURL
            value.meeting = value.meeting ?? current.meeting
            value.memberCount = value.memberCount ?? current.memberCount
            if value.members.isEmpty {
                value.members = current.members
            }
            if value.kind == .directMessage, current.kind == .appDirectMessage {
                value.kind = current.kind
            }
        }
        return value
    }
}
