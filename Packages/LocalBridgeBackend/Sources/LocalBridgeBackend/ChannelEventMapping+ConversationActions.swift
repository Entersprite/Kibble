import ChatKit
import Foundation
import GChatBridgeCore

extension ChannelEventMapping {
    /// Body fields from the vendored reference: tags 16/32/37 carry their
    /// payloads in fields 15/29/32. A malformed body is still routed unknown.
    static func conversationActionEvent(in body: ChannelEventBody) -> ChatEvent? {
        switch body.typeTag {
        case 16:
            guard let payload = field(15, in: body.value), isTrue(field(2, in: payload)),
                  let id = actionConversation(in: payload) else { return nil }
            return .conversationRemoved(conversationID: id, historyBefore: nil)
        case 32:
            guard let payload = field(29, in: body.value), isTrue(field(3, in: payload)),
                  let id = actionConversation(in: payload),
                  let micros = micros(field(2, in: payload)), micros > 0 else { return nil }
            return .conversationRemoved(conversationID: id, historyBefore: Microseconds.date(micros))
        case 37:
            guard let payload = field(32, in: body.value),
                  let id = actionConversation(in: payload),
                  let micros = micros(field(2, in: payload)) else { return nil }
            return .conversationUnreadMarkChanged(
                conversationID: id,
                at: micros > 0 ? Microseconds.date(micros) : nil
            )
        default: return nil
        }
    }

    private static func micros(_ value: PBLiteValue?) -> Int64? {
        guard let value else { return nil }
        return value.intValue.map(Int64.init) ?? value.stringValue.flatMap(Int64.init)
    }

    private static func isTrue(_ value: PBLiteValue?) -> Bool {
        value == .bool(true) || value?.intValue == 1
    }

    private static func actionConversation(in payload: PBLiteValue) -> Conversation.ID? {
        guard let value = field(1, in: payload) else { return nil }
        return conversationID(PBLiteDecoder.decode(GroupId.self, from: value).message)
    }

    private static func field(_ number: Int, in value: PBLiteValue) -> PBLiteValue? {
        if let object = value.objectValue {
            return object[String(number)]
        }
        guard let array = value.arrayValue else { return nil }
        if array.count >= number, array[number - 1] != .null {
            return array[number - 1]
        }
        return array.last?.objectValue?[String(number)]
    }
}
