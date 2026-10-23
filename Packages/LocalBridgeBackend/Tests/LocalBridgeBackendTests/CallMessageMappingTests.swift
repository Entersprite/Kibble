import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct CallMessageMappingTests {
    @Test func referenceMetadataIsMappedThroughTheActualPbliteDecoder() throws {
        let meet = fields([1: "\"abc-defg-hij\"", 2: "\"https://meet.google.com/abc-defg-hij\""])
        let metadata = fields([
            1: fields([1: meet]), 2: "3",
            3: fields([1: "\"1700000000\"", 2: "125000000"]),
            4: fields([1: "\"1700000001\"", 2: "250000000"])
        ])
        let json = messageJSON(status: 3, call: metadata)
        let value = try PBLiteValue(json: Data(json.utf8))
        let wire = PBLiteDecoder.decode(GChatBridgeCore.Message.self, from: value).message
        let message = try #require(ChannelEventMapping.domainMessage(wire))
        #expect(message.callStatus == .ended)
        #expect(message.callMetadata == MessageCallMetadata(
            reference: "abc-defg-hij", joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            endedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            participantsChangedAt: Date(timeIntervalSince1970: 1_700_000_001.250)
        ))
        var response = ListTopicsResponse()
        var topic = Topic(); topic.replies = [wire]; response.topics = [topic]
        #expect(HistoryMapping.map(response).messages.first?.callMetadata == message.callMetadata)
    }

    @Test func malformedLinksAndDatesCannotBecomeJoinTargetsOrEraseCallStatus() throws {
        for url in [
            "http://meet.google.com/abc-defg-hij", "https://meet.google.com.evil.test/abc-defg-hij",
            "https://user@meet.google.com/abc-defg-hij", "https://meet.google.com/call?secret=value",
            "https://meet.google.com/another-code", "https://meet.google.com:443/abc-defg-hij"
        ] {
            var wire = try decodedMessage(status: 1)
            var integration = wire.annotations[0].gsuiteIntegrationMetadata
            integration.callData.callMetadata.meetMetadata.meetingCode = "abc-defg-hij"
            integration.callData.callMetadata.meetMetadata.meetingURL = url
            integration.callData.callEndedTimestamp.seconds = 1_700_000_000
            integration.callData.callEndedTimestamp.nanos = -1
            wire.annotations[0].gsuiteIntegrationMetadata = integration
            let message = try #require(ChannelEventMapping.domainMessage(wire))
            #expect(message.callStatus == .started)
            #expect(message.callMetadata?.reference == "abc-defg-hij")
            #expect(message.callMetadata?.joinURL == nil && message.callMetadata?.endedAt == nil)
        }
    }

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

    private func messageJSON(status: Int, client: Int = 1, type: Int = 17, call: String? = nil) -> String {
        let group = fields([3: fields([1: "\"dm\""])])
        let topic = fields([2: "\"thread\"", 3: group])
        let id = fields([1: fields([4: topic]), 2: "\"message\""])
        let call = call ?? fields([2: String(status)])
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
