import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetPushTopicTests {
    @Test(arguments: ["topic with space", "topic\u{0}part", "topic\r\npart", "témakör", "topic\u{1F}part"])
    func opaqueTopicsSurviveShellParsingAndJSONEncodingExactly(_ topic: String) throws {
        let fields: [String: Any] = [
            "qwAQke": "DynamiteWebUi", "wU9aJb": "KEY", "pZ68sc": "PROJECT", "ttqQxf": topic
        ]
        let json = try JSONSerialization.data(withJSONObject: fields)
        let html = "<script>window.WIZ_global_data=\(String(decoding: json, as: UTF8.self));</script>"
        let wiz = try #require(WizGlobalData(html: html))
        let config = try #require(wiz.meetPushConfiguration)
        #expect(config.topic.utf8.elementsEqual(topic.utf8))
        #expect(wiz.meetPushDiagnostics
            .contains("Meet watch config ttqQxf: string, \(topic.utf8.count) bytes, valid"))
        let request = try PunctualRequests(meet: config, endpoints: ChatEndpoints())
            .chooseServer(.meetRings(config))
        let body = try #require(request.body)
        let root = try #require(PBLiteValue(json: body).arrayValue)
        let envelope = try #require(root.first?.arrayValue)
        let prefix = try #require(envelope[5].arrayValue)
        let parts = try #require(prefix[2].arrayValue?.first?.arrayValue)
        let encoded = try #require(parts.first?.arrayValue?.first?.stringValue)
        #expect(encoded.utf8.elementsEqual(topic.utf8))
        #expect(!config.description.contains(topic))
    }

    @Test func topicRemainsOnePathPartEvenWhenItLooksLikeJSONOrHasSlashes() throws {
        let topic = #"private/part",["other-project"]"#
        let config = try #require(MeetPushConfiguration(key: "KEY", project: "PROJECT", topic: topic))
        let watch = try PunctualWatch(sequence: 1, topic: .meetRings(config)).json()
        let root = try #require(PBLiteValue(json: Data(watch.utf8)).arrayValue)
        let operation = try #require(root.first?.arrayValue?.first?.arrayValue)
        let envelope = try #require(operation[1].arrayValue)
        let prefix = try #require(envelope[5].arrayValue)
        let parts = try #require(prefix[2].arrayValue?.first?.arrayValue)
        #expect(parts.count == 1)
        #expect(parts.first?.arrayValue == [.string(topic)])
        #expect(!watch.contains("\n"))
    }

    @Test func topicBoundsCountBytesAndKeyAndProjectValidationStayStrict() {
        #expect(MeetPushConfiguration(key: "KEY", project: "PROJECT", topic: "") == nil)
        #expect(MeetPushConfiguration(
            key: "KEY",
            project: "PROJECT",
            topic: String(repeating: "é", count: 1024)
        ) != nil)
        #expect(MeetPushConfiguration(
            key: "KEY",
            project: "PROJECT",
            topic: String(repeating: "é", count: 1025)
        ) == nil)
        #expect(MeetPushConfiguration(key: "bad\r\nkey", project: "PROJECT", topic: "topic") == nil)
        #expect(MeetPushConfiguration(key: "KEY", project: "bad project", topic: "topic") == nil)
    }
}
