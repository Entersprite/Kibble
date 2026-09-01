import ChatKit
import Foundation
import GChatBridgeCore

/// Wire events becoming domain events.
///
/// This is the translation the architecture puts in exactly one place: the core
/// knows nothing about `ChatKit`, and `ChatKit` knows nothing about protobuf, so
/// the package that imports both is where they meet.
///
/// ## Two rules, both from `findings.md` §12.1.1
///
/// **Nothing is dropped.** The vendored proto's `EventType` stops at 50 and live
/// traffic carried 51, 64, 70 and 83 — so a mapping that handled only what it
/// recognised would silently lose four kinds of event, and regenerating from a
/// newer proto would shrink that set without ever emptying it. Everything this
/// does not map becomes `.unknown`, which is the case `ChatKit` added for
/// precisely this and which re-encodes verbatim.
///
/// **Nameable is not the same as mapped.** `SESSION_READY` has a name in the
/// proto and no domain meaning here; it is routed exactly like tag 64. Treating
/// "the proto knows this" as "we handle this" is how events go missing while
/// every test still passes.
public enum ChannelEventMapping {
    /// The discriminator for a routed event.
    ///
    /// The **number** is the identity, not the proto's name for it: `ChatKit`'s
    /// wire rule is that an unknown discriminator re-encodes verbatim, and a
    /// generated Swift case name is not a thing to promise across versions. A
    /// tag the proto cannot name has no name to use anyway.
    static func discriminator(for tag: Int?) -> String {
        "googlechat.eventType.\(tag.map(String.init) ?? "untagged")"
    }

    /// Maps one channel event's bodies onto domain events, one for one.
    public static func chatEvents(from event: ChannelEvent) -> [ChatEvent] {
        event.bodies.map(chatEvent(from:))
    }

    private static func chatEvent(from body: ChannelEventBody) -> ChatEvent {
        guard let message = message(in: body) else {
            return routed(body)
        }
        switch body.type {
        case .messagePosted: return .messageReceived(message)
        case .messageUpdated: return .messageUpdated(message)
        default: return routed(body)
        }
    }

    private static func routed(_ body: ChannelEventBody) -> ChatEvent {
        .unknown(
            type: discriminator(for: body.typeTag),
            payload: JSONValue(body.value)
        )
    }

    /// Decodes the message out of a `MESSAGE_POSTED` or `MESSAGE_UPDATED` body.
    ///
    /// Returns `nil` when the body is not one of those, or when it is and the
    /// message lacks the identity a domain message cannot be built without. The
    /// caller routes it instead — **a `Message` with an invented id is
    /// indistinguishable from a real one once it is in the store**, which makes
    /// fabricating one worse than admitting the body was not understood.
    private static func message(in body: ChannelEventBody) -> ChatKit.Message? {
        guard body.type == .messagePosted || body.type == .messageUpdated else { return nil }
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: body.value)
        // **Both arrive in body field 6.** The vendored proto has no
        // `message_updated` member in `EventBody`'s oneof at all, and the
        // captures confirm an edit populates the same field a post does - so
        // the *type tag* is the only thing that tells them apart, and reading
        // the body alone would call every edit a new message.
        guard case let .messagePosted(event)? = decoded.message.type else { return nil }
        return domainMessage(event.message)
    }

    private static func domainMessage(_ message: GChatBridgeCore.Message) -> ChatKit.Message? {
        let identifier = message.id.messageID
        guard !identifier.isEmpty else { return nil }
        guard let conversationID = conversationID(message.id.parentID.topicID.groupID) else {
            return nil
        }
        return ChatKit.Message(
            id: ChatKit.Message.ID(identifier),
            conversationID: conversationID,
            threadID: MessageThread.ID(message.id.parentID.topicID.topicID),
            sender: Member.ID(message.creator.userID.id),
            text: message.textBody,
            // Microseconds since the epoch, and they arrive as a *string*:
            // pblite sends 64-bit values that way because a 16-digit number does
            // not survive JSON's binary64. `PBLiteDecoder` coerces it back.
            createdAt: Date(timeIntervalSince1970: Double(message.createTime) / 1_000_000),
            editedAt: message.hasLastEditTime
                ? Date(timeIntervalSince1970: Double(message.lastEditTime) / 1_000_000)
                : nil,
            isDeleted: message.hasDeleteTime && message.deleteTime > 0
        )
    }

    /// A space id and a DM id are different namespaces on the wire.
    ///
    /// Prefixed rather than flattened, so two conversations that happen to share
    /// a raw identifier cannot merge into one. Anything else building a
    /// `Conversation.ID` from this protocol has to use this same function, which
    /// is why it is the only place the rule is written.
    static func conversationID(_ group: GroupId) -> Conversation.ID? {
        switch group.id {
        case let .spaceID(space) where !space.spaceID.isEmpty:
            Conversation.ID("space/\(space.spaceID)")
        case let .dmID(dm) where !dm.dmID.isEmpty:
            Conversation.ID("dm/\(dm.dmID)")
        default:
            nil
        }
    }
}

// MARK: - Carrying an unmapped body across the seam

extension JSONValue {
    /// Converts a pblite tree into the seam's JSON vocabulary.
    ///
    /// Lossless except in one place, and that place is documented rather than
    /// hidden: `JSONValue.number` is a `Double`, so an integer too large to be
    /// exact in one becomes a **string**. pblite already sends 64-bit values as
    /// strings for the same reason, so this matches what the wire does with them
    /// — and silently rounding an id would be far worse than changing its type.
    init(_ value: PBLiteValue) {
        switch value {
        case .null:
            self = .null
        case let .bool(flag):
            self = .bool(flag)
        case let .string(text):
            self = .string(text)
        case let .array(items):
            self = .array(items.map(JSONValue.init))
        case let .object(entries):
            self = .object(entries.mapValues(JSONValue.init))
        case let .number(number):
            self = JSONValue(number)
        }
    }

    private init(_ number: PBLiteNumber) {
        switch number {
        case let .double(value):
            self = .number(value)
        case let .integer(value):
            self = Double(exactly: value).map(JSONValue.number) ?? .string(String(value))
        case let .unsigned(value):
            self = Double(exactly: value).map(JSONValue.number) ?? .string(String(value))
        }
    }
}
