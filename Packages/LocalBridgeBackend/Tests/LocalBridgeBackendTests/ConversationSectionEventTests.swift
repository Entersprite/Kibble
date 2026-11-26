import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct ConversationSectionEventTests {
    @Test(arguments: [70, 71])
    func groupLabelsInvalidateTheSectionListAndKeepGroupRevisionScope(tag: Int) throws {
        let change = try decode(tag, json: #"[{"57":[[["room"]],[4,"key"]]}]"#)
        let conversation = Conversation.ID("space/room")
        #expect(change == .conversationSectionsChanged(conversationID: conversation))
        #expect(LocalBridgeBackend.recoveryConversation(change) == conversation)
    }

    @Test(arguments: [72, 73, 74])
    func onlyDeletesCarryTheExactSectionIdentifier(tag: Int) throws {
        let change = try decode(tag, json: #"[{"58":[[[3,null,"sidebar"],null,"Section name"]]}]"#)
        #expect(change == .conversationSectionsChanged(removedSectionID: tag == 73 ? "sidebar" : nil))
    }

    @Test func nonCustomLabelsAndMalformedDeletesRetainTheirPayloads() throws {
        for (tag, json) in [
            (70, #"[{"57":[[["room"]],[1,"other"]]}]"#),
            (73, #"[{"58":[[[3]]]}]"#)
        ] {
            let value = try PBLiteValue(json: Data(json.utf8))
            #expect(try decode(tag, json: json) == .unknown(
                type: "googlechat.eventType.\(tag)", payload: JSONValue(value)
            ))
        }
    }

    @Test func binaryRecoveryDeliversAnIdenticalSectionDeletion() throws {
        var event = Event()
        event.type = .rosterSectionDeleted
        event.body.rosterSectionChanged.section.id.type = 3
        event.body.rosterSectionChanged.section.id.id = "retired"
        let bytes: Data = try event.serializedBytes()
        let replay = try ChannelEvent(protobuf: Event(serializedBytes: bytes))
        #expect(ChannelEventMapping.chatEvents(from: replay) == [.conversationSectionsChanged(
            removedSectionID: "retired"
        )])
    }

    private func decode(_ tag: Int, json: String) throws -> ChatEvent {
        let body = try ChannelEventBody(typeTag: tag, value: PBLiteValue(json: Data(json.utf8)))
        return try #require(ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [body])).first)
    }
}
