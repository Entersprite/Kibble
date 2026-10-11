import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `searchMessages(_:after:)`'s request shape: each `MessageSearchQuery`
/// filter, translated into `SBNmJb`'s own wire positions (§65.5), via
/// `SearchBackendSupport.connected(_:)` and `SearchFixtures`.
@Suite(.timeLimit(.minutes(1)))
struct SearchMessagesFilterTests {
    @Test func theTextAloneSendsNoFilter() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        _ = try await backend.searchMessages(MessageSearchQuery(text: "hello"), after: nil)
        let sent = try #require(await SearchBackendSupport.batchRequests(transport).first)
        let payload = try SearchFixtures.innerPayload(of: sent)
        #expect(payload[3] as? String == "hello")
        let filter = try #require(payload[6] as? [Any])
        #expect((filter[0] as? [Any])?.isEmpty == true)
        #expect(filter[1] is NSNull)
        #expect(filter[6] as? Int == 0)
    }

    @Test func fromBecomesTheUserIDAtFilterIndexOne() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        _ = try await backend.searchMessages(
            MessageSearchQuery(text: "x", from: Member.ID("u-77")), after: nil
        )
        let sent = try #require(await SearchBackendSupport.batchRequests(transport).first)
        let filter = try #require(try SearchFixtures.innerPayload(of: sent)[6] as? [Any])
        #expect((filter[1] as? [[String]])?.first == ["u-77"])
    }

    @Test func conversationBecomesTheSpacesGroupReference() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        _ = try await backend.searchMessages(
            MessageSearchQuery(text: "x", conversation: Conversation.ID("space/sp-9")), after: nil
        )
        let sent = try #require(await SearchBackendSupport.batchRequests(transport).first)
        let filter = try #require(try SearchFixtures.innerPayload(of: sent)[6] as? [Any])
        let saidIn = try #require(filter[0] as? [Any])
        let groupRef = try #require(saidIn[1] as? [Any])
        #expect(groupRef[0] as? String == "space/sp-9")
        #expect(groupRef[1] as? String == "sp-9")
        #expect(groupRef[2] as? Int == 2)
    }

    @Test func olderThanBecomesMicrosecondsAsADecimalString() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        let date = Microseconds.date(1_700_000_123_456_789)
        _ = try await backend.searchMessages(MessageSearchQuery(text: "x", olderThan: date), after: nil)
        let sent = try #require(await SearchBackendSupport.batchRequests(transport).first)
        let filter = try #require(try SearchFixtures.innerPayload(of: sent)[6] as? [Any])
        let bound = try #require(filter[2] as? [Any])
        #expect(bound[0] is NSNull)
        #expect(bound[1] as? String == "1700000123456789")
    }

    @Test func hasFileBecomesFilterIndexThree() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        _ = try await backend.searchMessages(MessageSearchQuery(text: "x", hasFile: true), after: nil)
        let sent = try #require(await SearchBackendSupport.batchRequests(transport).first)
        let filter = try #require(try SearchFixtures.innerPayload(of: sent)[6] as? [Any])
        #expect(filter[3] as? [[Int]] == [[2]])
    }

    @Test func hasLinkBecomesFilterIndexSixEqualOne() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        _ = try await backend.searchMessages(MessageSearchQuery(text: "x", hasLink: true), after: nil)
        let sent = try #require(await SearchBackendSupport.batchRequests(transport).first)
        let filter = try #require(try SearchFixtures.innerPayload(of: sent)[6] as? [Any])
        #expect(filter[6] as? Int == 1)
    }

    @Test func mentionsMeUsesTheLocalUsersOwnID() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        _ = try await backend.searchMessages(MessageSearchQuery(text: "x", mentionsMe: true), after: nil)
        let sent = try #require(await SearchBackendSupport.batchRequests(transport).first)
        let filter = try #require(try SearchFixtures.innerPayload(of: sent)[6] as? [Any])
        #expect(filter[5] as? [[[[String]]]] == [[[["u-me"]]]])
    }

    @Test func newestFirstSetsTheOrderSlotToTwo() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        _ = try await backend.searchMessages(MessageSearchQuery(text: "x", order: .newest), after: nil)
        let sent = try #require(await SearchBackendSupport.batchRequests(transport).first)
        #expect(try SearchFixtures.innerPayload(of: sent)[8] as? [Int] == [2])
    }
}
