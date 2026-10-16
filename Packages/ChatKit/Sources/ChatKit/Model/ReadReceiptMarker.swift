import Foundation

/// One marker moves through the transcript. Each reader must cover this exact message.
public struct ReadReceiptMarker: Hashable, Sendable {
    public var messageID: Message.ID
    public var readers: [Member.ID]

    public static func latest(
        in messages: [Message],
        positions: [ReadPosition],
        me: Member.ID?,
        excluding pending: Set<Message.ID> = []
    ) -> Self? {
        guard let me else { return nil }
        var latest: [Member.ID: Date] = [:]
        for position in positions where position.member != me {
            latest[position.member] = max(latest[position.member] ?? .distantPast, position.readThrough)
        }
        for message in messages.reversed() where message.sender == me && !message.isDeleted
            && !message.isReply && !pending.contains(message.id) {
            let readers = latest.filter { $0.value >= message.createdAt }.map(\.key)
                .sorted { $0.rawValue < $1.rawValue }
            if !readers.isEmpty {
                return Self(messageID: message.id, readers: readers)
            }
        }
        return nil
    }
}
