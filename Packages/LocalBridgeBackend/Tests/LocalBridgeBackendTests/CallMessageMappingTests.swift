import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct CallMessageMappingTests {
    @Test func theWireAnnotationSurvivesLivePostsEditsAndHistory() throws {
        for (raw, expected) in [
            (1, MessageCallStatus.started),
            (2, .missed),
            (3, .ended),
            (99, .unknown("99"))
        ] {
            let wire = try decodedMessage(status: raw)
            #expect(ChannelEventMapping.domainMessage(wire)?.callStatus == expected)
            var response = ListTopicsResponse()
            var topic = Topic(); topic.replies = [wire]; response.topics = [topic]
            #expect(HistoryMapping.map(response).messages.first?.callStatus == expected)
            for tag in [6, 7] {
                let body = try fields([6: fields([1: messageJSON(status: raw)]), 12: String(tag)])
                let wrapper = fields([8: "[\(body)]"])
                let value = try PBLiteValue(json: Data("[[\(wrapper),\"wrapper\"]]".utf8))
                let event = try #require(ChannelEvent(ChannelArray(aid: 1, data: value)))
                let mapped = ChannelEventMapping.chatEvents(from: event)
                switch mapped.first {
                case let .messageReceived(message)?, let .messageUpdated(message)?:
                    #expect(message.callStatus == expected)
                default: Issue.record("Expected a mapped call message")
                }
            }
        }
    }

    @Test func otherIntegrationsAndOrdinaryWordsAreNotCallActivity() throws {
        #expect(try ChannelEventMapping.domainMessage(decodedMessage(status: 1, client: 2))?
            .callStatus == nil)
        #expect(try ChannelEventMapping.domainMessage(decodedMessage(status: 1, type: 11))?.callStatus == nil)
        var ordinary = try decodedMessage(status: 1)
        ordinary.annotations = []
        #expect(ChannelEventMapping.domainMessage(ordinary)?.callStatus == nil)
    }

    private func decodedMessage(status: Int, client: Int = 1, type: Int = 17) throws -> GChatBridgeCore
        .Message {
        let value = try PBLiteValue(json: Data(messageJSON(status: status, client: client, type: type).utf8))
        return PBLiteDecoder.decode(GChatBridgeCore.Message.self, from: value).message
    }

    private func messageJSON(status: Int, client: Int = 1, type: Int = 17) -> String {
        let group = fields([3: fields([1: "\"dm\""])])
        let topic = fields([2: "\"thread\"", 3: group])
        let id = fields([1: fields([4: topic]), 2: "\"message\""])
        let call = fields([2: String(status)])
        let integration = fields([1: String(client), 6: call])
        let annotation = fields([1: String(type), 16: integration])
        return fields([
            1: id, 2: fields([1: fields([1: "\"peer\""])]), 3: "\"1700000000000000\"",
            10: "\"Call started\"", 11: "[\(annotation)]"
        ])
    }

    private func fields(_ values: [Int: String]) -> String {
        "[" + (1 ... (values.keys.max() ?? 1)).map { values[$0] ?? "null" }.joined(separator: ",") + "]"
    }
}
