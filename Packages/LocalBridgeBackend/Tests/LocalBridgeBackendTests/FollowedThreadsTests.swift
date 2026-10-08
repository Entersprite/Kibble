import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Home's Threads list answer (`findings.md` §64.6): topics arrive as top-level field 7, repeated
/// `WorldEntity` `{1: Topic | 3: Message, 2: UserProfile}`. And the write round trips' target.
struct FollowedThreadsTests {
    private func topicBytes(_ id: String, replies: Int, summaryTotal: UInt64?) throws -> Data {
        var topic = GChatBridgeCore.Topic()
        topic.id.topicID = id
        topic.replies = (0 ..< replies).map { index in
            var message = GChatBridgeCore.Message()
            message.id.messageID = "\(id)-\(index)"
            message.textBody = "secret words"
            return message
        }
        if let summaryTotal {
            var state = ProbeProtoWriter()
            state.message(13) { $0.varint(1, summaryTotal) }
            topic.topicReadState = try TopicReadState(serializedBytes: state.data)
        }
        return ThreadRequests.bytes(of: topic)
    }

    private func answer() throws -> Data {
        let first = try topicBytes("secrettopic", replies: 2, summaryTotal: 4)
        let second = try topicBytes("secretother", replies: 1, summaryTotal: nil)
        var body = ProbeProtoWriter()
        body.message(1) { $0.bool(5, true) }
        body.message(7) { entity in
            entity.bytes(1, first)
            entity.message(2) { $0.bytes(1, Data("secret profile".utf8)) }
        }
        body.message(7) { $0.message(3) { $0.bytes(10, Data("secret text".utf8)) } }
        body.message(7) { $0.bytes(1, second) }
        return body.data
    }

    @Test func entitiesAreCountedByKindAndTopicsByRepliesAndSummary() throws {
        let shape = try APIProbeReport.followedThreadsShape(answer())
        #expect(shape.topLevelFields == [1: 1, 7: 3])
        #expect(shape.sectionFields == [5: 1])
        #expect(shape.entities == 3)
        #expect(shape.entityKinds == ["1+2": 1, "3": 1, "1": 1])
        #expect(shape.messagesPerTopic == [2: 1, 1: 1])
        #expect(shape.summaryTotals == [4: 1])
        #expect(shape.topicsWithoutSummary == 1)
    }

    @Test func noFollowedThreadsLineCarriesAnIDOrText() throws {
        let text = try APIProbeReport.followedThreadsLines(APIProbeReport.followedThreadsShape(answer()))
            .joined(separator: "\n")
        #expect(text.contains("entities: 3"))
        #expect(!text.contains("secret"))
    }

    @Test func anEmptyAnswerSaysSo() {
        let lines = APIProbeReport.followedThreadsLines(APIProbeReport.followedThreadsShape(Data()))
        #expect(lines.contains { $0.contains("entities: 0") })
    }

    // MARK: - The write round trips' target

    private func thread(_ id: String, sort: Int64, times: [Int64]) -> GChatBridgeCore.Topic {
        var topic = GChatBridgeCore.Topic()
        topic.id.topicID = id
        topic.sortTime = sort
        topic.replies = times.enumerated().map { index, time in
            var message = GChatBridgeCore.Message()
            message.id.messageID = index == 0 ? id : "\(id)-\(index)"
            message.id.parentID.topicID.topicID = id
            message.id.parentID.topicID.groupID.dmID.dmID = "d-1"
            message.createTime = time
            return message
        }
        return topic
    }

    @Test func theTargetIsTheMostRecentlyActiveThreadAndItsNewestMessage() {
        let target = APIProbeReport.threadWriteTarget(in: [
            thread("single", sort: 90, times: [90]),
            thread("older", sort: 50, times: [10, 50]),
            thread("newer", sort: 80, times: [30, 80, 70])
        ])
        #expect(target?.topic.topicID == "newer")
        #expect(target?.topic.groupID.dmID.dmID == "d-1")
        #expect(target?.newestMicros == 80)
    }

    @Test func noThreadMeansNoTarget() {
        #expect(APIProbeReport.threadWriteTarget(in: [thread("single", sort: 1, times: [1])]) == nil)
    }

    // MARK: - The write round trips refuse an unnamed conversation

    private func roundTrips(_ conversation: ProbeConversation) async throws -> (lines: [String], sent: Int) {
        let transport = ScriptedTransport([])
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        var group = GroupId()
        group.dmID.dmID = "d-1"
        var lines: [String] = []
        await APIProbeReport.appendThreadWriteRoundTrips(
            client: client, group: group, conversation: conversation, lines: &lines
        )
        let sent = await transport.sent.count
        return (lines, sent)
    }

    /// Each step changes the owner's account, so with no `--probe-conversation=` nothing is sent:
    /// the most recently active conversation may be anyone's.
    @Test func anUnnamedConversationIsRefusedBeforeAnyCall() async throws {
        let outcome = try await roundTrips(.mostRecent)
        #expect(outcome.sent == 0)
        #expect(outcome.lines.contains { $0.contains("refused") })
    }

    /// The positive control: a named conversation does reach the network, so the test above is
    /// the guard's and not a harness that sends nothing.
    @Test func aNamedConversationIsAskedForItsThreads() async throws {
        let outcome = try await roundTrips(.mostRecentDirectMessage)
        #expect(outcome.sent > 0)
        #expect(!outcome.lines.contains { $0.contains("refused") })
    }
}
