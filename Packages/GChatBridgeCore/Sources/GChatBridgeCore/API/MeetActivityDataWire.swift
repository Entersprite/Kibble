import Foundation

public enum MeetActivityDataWire {
    public enum MessageError: Error, Sendable { case rejected }
    public enum ChatRecipient: UInt64, Sendable {
        case everyone = 0, waitingRoom = 2
    }

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

    public static func chat(
        _ text: String,
        sequence: UInt64,
        recipient: ChatRecipient = .everyone
    ) throws -> Data {
        try MeetActivityWire.validateText(text, maximum: 4000)
        let message = MeetProto.number(3, sequence) + MeetProto.bytes(5, MeetProto.string(1, text))
            + MeetProto.number(6, 1) + MeetProto.number(10, recipient.rawValue)
        return MeetProto.bytes(
            1,
            MeetProto.number(1, sequence)
                + MeetProto.bytes(3, MeetProto.bytes(1, MeetProto.bytes(2, message)))
        )
    }

    public static func isChatResponse(_ data: Data, sequence: UInt64) -> Bool {
        (try? matchingChatStatus(data, sequence: sequence)) != nil
    }

    public static func chatResponse(
        _ data: Data,
        sequence: UInt64,
        recipient: ChatRecipient = .everyone
    ) throws -> Data {
        let (response, code) = try matchingChatStatus(data, sequence: sequence)
        guard code == 0 else { throw MessageError.rejected }
        let message = try MeetProto.payload(1, MeetProto.payload(4, response))
        try MeetProto.validate(message)
        let matches = recipient == .everyone ? isPublicChatRecipient(message) : isWaitingRoomChatText(message)
        guard matches else { throw MeetCallWire.WireError.malformedResponse }
        if recipient == .waitingRoom {
            let name = try MeetProto.text(1, message)
            let body = try MeetProto.payload(5, message)
            guard let text = MeetActivityCollections.text(1, body) else {
                throw MeetCallWire.WireError.malformedResponse
            }
            try MeetActivityWire.validateText(name, maximum: 512)
            try MeetActivityWire.validateText(text, maximum: 4000)
        }
        return message
    }

    public static func chatResponseShape(_ data: Data, sequence: UInt64) -> String {
        guard let (response, code) = try? matchingChatStatus(data, sequence: sequence) else {
            return "no addressed status"
        }
        guard let variant = try? MeetProto.payload(4, response),
              let message = try? MeetProto.payload(1, variant) else {
            return "status=\(min(code, 99)); no create message"
        }
        let type = (try? MeetProto.value(6, message)).map { String(min($0, 99)) } ?? "omitted"
        let recipient = (try? MeetProto.value(10, message)).map { String(min($0, 99)) } ?? "omitted"
        return "status=\(min(code, 99)); type=\(type); recipient=\(recipient)"
    }

    public static func chatCreateRevision(_ data: Data, sequence: UInt64) -> UInt64? {
        guard let (response, code) = try? matchingChatStatus(data, sequence: sequence), code == 0,
              let update = try? MeetProto.payload(4, response) else { return nil }
        return chatRevision(in: update)
    }

    public static func updateChatPin(name: String, pinned: Bool, sequence: UInt64) throws -> Data {
        try MeetActivityWire.validateText(name, maximum: 512)
        let message = MeetProto.string(1, name) + MeetProto.number(7, pinned ? 1 : 0)
        let update = MeetProto.bytes(1, message)
            + MeetProto.bytes(2, MeetProto.string(1, "is_pinned"))
        return MeetProto.bytes(
            1,
            MeetProto.number(1, sequence)
                + MeetProto.bytes(4, MeetProto.bytes(1, update))
        )
    }

    public static func publicChatPin(in message: Data) -> Bool? {
        guard isPublicChatText(message) else { return nil }
        return pinValue(in: message)
    }

    public static func isPublicChatText(_ message: Data) -> Bool {
        (try? MeetProto.value(6, message)) == 1 && isPublicChatRecipient(message)
    }

    public static func isWaitingRoomChatText(_ message: Data) -> Bool {
        (try? MeetProto.value(6, message)) == 1 && (try? MeetProto.value(10, message)) == 2
    }

    public static func chatPinRevision(
        _ data: Data, sequence: UInt64, name: String, pinned: Bool
    ) throws -> UInt64? {
        let (response, code) = try matchingChatStatus(data, sequence: sequence)
        guard code == 0 else { throw MessageError.rejected }
        guard MeetActivityCollections.has(5, response) else { return nil }
        let update = try MeetProto.payload(5, response)
        guard MeetActivityCollections.has(1, update) else { return nil }
        let message = try MeetProto.payload(1, update)
        guard MeetActivityCollections.has(1, message) else { return nil }
        guard try MeetProto.text(1, message) == name, isPublicChatRecipient(message)
        else { throw MeetCallWire.WireError.malformedResponse }
        guard pinValue(in: message) == pinned else { return nil }
        return chatRevision(in: update)
    }

    private static func chatRevision(in update: Data) -> UInt64? {
        guard let version = MeetActivityCollections.text(5, update)?.split(separator: "-").first,
              let revision = UInt64(version), revision > 0 else { return nil }
        return revision
    }

    private static func isPublicChatRecipient(_ message: Data) -> Bool {
        guard MeetActivityCollections.has(10, message) else { return true }
        guard let recipient = try? MeetProto.value(10, message) else { return false }
        // The web transcript groups these ordinary in-call audience values.
        // The service returned 1 for a browser message and 4 in a create receipt.
        return recipient == 0 || recipient == 1 || recipient == 4
    }

    private static func pinValue(in message: Data) -> Bool? {
        guard MeetActivityCollections.has(7, message) else { return false }
        guard let value = try? MeetProto.value(7, message), value <= 1 else { return nil }
        return value == 1
    }

    private static func matchingChatStatus(_ data: Data, sequence: UInt64) throws -> (Data, UInt64) {
        let response = try MeetProto.payload(1, data)
        guard try MeetProto.value(1, response) == sequence
        else { throw MeetCallWire.WireError.malformedResponse }
        guard MeetActivityCollections.has(2, response) else {
            // A successful result can omit the default status. An ID alone
            // still cannot correlate a frame with no operation result.
            guard MeetActivityCollections.has(4, response) || MeetActivityCollections.has(5, response)
            else { throw MeetCallWire.WireError.malformedResponse }
            return (response, 0)
        }
        let status = try MeetProto.payload(2, response)
        try MeetProto.validate(status)
        // Protobuf defaults an absent code to OK. A present code must decode.
        let hasCode = ProtoFieldScan.fields(in: status).fields.contains { $0.number == 1 }
        return try (response, hasCode ? MeetProto.value(1, status) : 0)
    }
}
