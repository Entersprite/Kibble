import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Paging (§65.2: a later page resends its query's own id and every filter)
/// and what the server can answer besides a clean page: an error code, a
/// non-200, or a body that is not a `batchexecute` answer at all (an HTML
/// sign-in page - `CLAUDE.md`'s "auth failure returns HTTP 200").
@Suite(.timeLimit(.minutes(1)))
struct SearchMessagesPagingAndErrorsTests {
    @Test func page2ReusesTheQueryIDAndFiltersAndSendsTheTokenAndClock() async throws {
        let hit1 = SearchFixtures.hit(
            messageID: "m-1", spaceID: "sp-1", senderID: "u-1", text: "one", createdAtMicros: 1
        )
        let page1Inner = SearchFixtures.pageInner(nextToken: "tok-1", hits: [hit1])
        let page2Inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: page1Inner)),
            SearchFixtures.ok(SearchFixtures.answerBody(inner: page2Inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        let query = MessageSearchQuery(text: "x", from: Member.ID("u-77"))
        let page1 = try await backend.searchMessages(query, after: nil)
        let cursor = try #require(page1.next)
        _ = try await backend.searchMessages(query, after: cursor)

        let sent = await SearchBackendSupport.batchRequests(transport)
        #expect(sent.count == 2)
        let first = try SearchFixtures.innerPayload(of: sent[0])
        let second = try SearchFixtures.innerPayload(of: sent[1])

        // The token at 1 and the clock at 7 (§65.2).
        #expect(second[1] as? String == "tok-1")
        #expect(second[0] is NSNull)
        #expect(!(second[7] is NSNull))

        // The same query id, and the same filters (§65.2: "the same on every
        // page of one query").
        #expect(second[5] as? String == first[5] as? String)
        let firstFilter = try #require(first[6] as? [Any])
        let secondFilter = try #require(second[6] as? [Any])
        #expect((secondFilter[1] as? [[String]])?.first == (firstFilter[1] as? [[String]])?.first)
        // filter[4] is null on a later page (`SearchRequests.payload`'s own
        // existing rule, unchanged by this task).
        #expect(secondFilter[4] is NSNull)
    }

    @Test func anErrorCodeRowBecomesAServerError() async throws {
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner, errorCode: 7))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(MessageSearchQuery(text: "x"), after: nil)
        }
    }

    @Test func aNon200BecomesAServerError() async throws {
        let transport = SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            .success(HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data()))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        await #expect(throws: ChatError.server(status: 500, message: "the search batchexecute call")) {
            _ = try await backend.searchMessages(MessageSearchQuery(text: "x"), after: nil)
        }
    }

    /// Auth failure returns HTTP 200 (`CLAUDE.md`) - an HTML sign-in page at
    /// the `batchexecute` endpoint itself, rather than the shell.
    @Test func anHTMLBodyBecomesAnError() async throws {
        let html = "<html><body>Sign in - Google Accounts</body></html>"
        let transport = SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            .success(HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8)))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(MessageSearchQuery(text: "x"), after: nil)
        }
    }
}
