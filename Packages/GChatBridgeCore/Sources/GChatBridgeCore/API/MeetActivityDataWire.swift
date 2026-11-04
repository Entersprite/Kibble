import Foundation

public enum MeetActivityDataWire {
    public enum MessageError: Error, Sendable { case rejected }
    public struct Reaction: Sendable {
        public let emoji: String
        public let device: String
        public let displayName: String
    }

    public static let emoji = ["❤️", "👍", "🎉", "👏", "😂", "😮", "😢", "🤔", "👎"]
    public static func reaction(_ emoji: String, sequence: UInt64) throws -> Data {
        guard self.emoji.contains(emoji), sequence > 0 else { throw MeetCallWire.WireError.invalidIdentifier }
        return MeetProto.bytes(
            1,
            MeetProto.number(1, sequence)
                + MeetProto.bytes(2, MeetProto.bytes(1, MeetProto.string(1, emoji)))
        )
    }

    public static func reactions(_ data: Data) throws -> [Reaction] {
        try MeetProto.validate(data)
        guard data.count <= 64000, MeetActivityCollections.has(1, data) else { return [] }
        let push = try MeetProto.payload(1, data)
        var reactions: [Reaction] = []
        for group in ProtoFieldScan.payloads(ofField: 1, in: push).prefix(32) {
            let emoji = try MeetProto.text(1, MeetProto.payload(1, group))
            guard self.emoji.contains(emoji) else { continue }
            for device in ProtoFieldScan.payloads(ofField: 6, in: group).prefix(64) {
                let name = try MeetProto.text(1, device)
                guard name.utf8.count <= 512 else { throw MeetCallWire.WireError.malformedResponse }
                reactions.append(Reaction(
                    emoji: emoji,
                    device: name,
                    displayName: MeetActivityCollections
                        .text(2, device) ?? "Participant"
                ))
            }
        }
        return reactions
    }

    public static func chat(_ text: String, sequence: UInt64) throws -> Data {
        try MeetActivityWire.validateText(text, maximum: 4000)
        let message = MeetProto.number(3, sequence) + MeetProto.bytes(5, MeetProto.string(1, text))
            + MeetProto.number(6, 1) + MeetProto.number(10, 0)
        return MeetProto.bytes(
            1,
            MeetProto.number(1, sequence)
                + MeetProto.bytes(3, MeetProto.bytes(1, MeetProto.bytes(2, message)))
        )
    }

    public static func isChatResponse(_ data: Data, sequence: UInt64) -> Bool {
        guard let response = try? MeetProto.payload(1, data) else { return false }
        return (try? MeetProto.value(1, response)) == sequence
    }

    public static func chatResponse(_ data: Data, sequence: UInt64) throws -> Data {
        let response = try MeetProto.payload(1, data)
        guard try MeetProto.value(1, response) == sequence
        else { throw MeetCallWire.WireError.malformedResponse }
        let status = try MeetProto.payload(2, response)
        // protobuf Status.code defaults to OK when absent, but Status itself must exist.
        guard (MeetActivityCollections.number(1, status) ?? 0) == 0
        else { throw MessageError.rejected }
        return try MeetProto.payload(1, MeetProto.payload(4, response))
    }
}
