import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct SearchExtendedFilterTests {
    private func hit(_ id: String, micros: Int64, dm: String? = nil) -> [Any] {
        var hit = SearchFixtures.hit(
            messageID: id, spaceID: "space", senderID: "person", text: "word", createdAtMicros: micros
        )
        if let dm, var fields = hit[0] as? [Any], var address = fields[17] as? [Any],
           var topic = address[2] as? [Any] {
            let group: [Any] = ["dm/" + dm, dm]
            fields[2] = group
            topic[2] = group
            address[2] = topic
            fields[17] = address
            hit[0] = fields
        }
        return hit
    }

    @Test func directConversationAndLowerDateBoundFilterEveryPageWithoutGuessingRequestFields() async throws {
        let first = SearchFixtures.pageInner(nextToken: "next", hits: [
            hit("foreign", micros: 2_000_000), hit("equal", micros: 1_000_000, dm: "target")
        ])
        let second = SearchFixtures.pageInner(nextToken: nil, hits: [
            hit("older", micros: 999_999, dm: "target"),
            hit("wanted", micros: 1_000_001, dm: "target"),
            hit("other-dm", micros: 3_000_000, dm: "other")
        ])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: first)),
            SearchFixtures.ok(SearchFixtures.answerBody(inner: second))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        let query = MessageSearchQuery(
            text: "word", conversation: Conversation.ID("dm/target"), newerThan: Microseconds.date(1_000_000)
        )
        let page = try await backend.searchMessages(query, after: nil)
        #expect(page.hits.isEmpty)
        let cursor = try #require(page.next)
        let next = try await backend.searchMessages(query, after: cursor)
        #expect(next.hits.count == 1)
        #expect(next.hits.first?.conversationID == query.conversation)
        #expect(next.hits.first?.createdAt == Microseconds.date(1_000_001))
        #expect(next.next == nil)
        let requests = await SearchBackendSupport.batchRequests(transport)
        #expect(requests.count == 2)
        for request in requests {
            let filter = try #require(try SearchFixtures.innerPayload(of: request)[6] as? [Any])
            #expect((filter[0] as? [Any])?.isEmpty == true)
            #expect(filter[2] is NSNull)
        }
        #expect(backend.capabilities.messageSearchFilters.contains(.newerThan))
        await backend.disconnect()
    }

    @Test func repeatedProviderCursorStopsInsteadOfScanningForever() async throws {
        let page = SearchFixtures.pageInner(nextToken: "same", hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: page)),
            SearchFixtures.ok(SearchFixtures.answerBody(inner: page))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        let query = MessageSearchQuery(text: "word", newerThan: Date(timeIntervalSince1970: 1))
        let first = try await backend.searchMessages(query, after: nil)
        let cursor = try #require(first.next)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(query, after: cursor)
        }
        await backend.disconnect()
    }
}
