import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Cancellation reaching the transport (`CLAUDE.md`: "a hold must throw when
/// canceled"), and a hit becoming a `ChatKit.Message` with its sender handed
/// to member resolution (`findings.md` §65.8: a hit carries no sender name).
@Suite(.timeLimit(.minutes(1)))
struct SearchMessagesCancelAndMapTests {
    @Test func cancellationReachesTheTransportAndStartsNothingAfter() async throws {
        let hold = SearchHold()
        let transport = SearchTransport(shell: SearchFixtures.fullShell(), hold: hold)
        let backend = try await SearchBackendSupport.connected(transport)
        // `connect()` already ran its own `get_members` lookup for "u-me"
        // (self-identification) - this is the baseline the search itself
        // must not add to.
        let memberLookupsBeforeSearch = await transport.sent
            .filter { $0.url.path.contains("/api/get_members") }.count
        let task = Task {
            try await backend.searchMessages(MessageSearchQuery(text: "x"), after: nil)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await hold.aborted == 1)
        // Nothing past the cancelled send ran: no member lookup was started
        // for the search's own hits (there are none to map, since the send
        // never returned).
        try await Task.sleep(for: .milliseconds(20))
        let memberLookupsAfter = await transport.sent
            .filter { $0.url.path.contains("/api/get_members") }.count
        #expect(memberLookupsAfter == memberLookupsBeforeSearch)
    }

    @Test func hitsAreMappedAndTheirSendersAreLookedUp() async throws {
        let hit1 = SearchFixtures.hit(
            messageID: "m-1", spaceID: "sp-1", senderID: "u-sender", text: "hello there",
            createdAtMicros: 1_700_000_000_000_000
        )
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [hit1])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        let page = try await backend.searchMessages(MessageSearchQuery(text: "hello"), after: nil)
        #expect(page.hits.count == 1)
        #expect(page.hits.first?.id.rawValue == "m-1")
        #expect(page.hits.first?.text == "hello there")
        #expect(page.hits.first?.sender.rawValue == "u-sender")
        #expect(page.next == nil)

        // `resolveAndEmitSelf()` already looked up "u-me" during `connect()`,
        // on the very same `/api/get_members` path, so this waits for a
        // request naming "u-sender" specifically rather than the first
        // `get_members` call of any kind.
        let found = try await SearchBackendSupport.waitFor(transport) { requests in
            requests.contains { request in
                guard request.url.path.contains("/api/get_members") else { return false }
                return (try? GetMembersRequest(serializedBytes: request.body ?? Data()))?
                    .memberIds.map(\.userID.id).contains("u-sender") == true
            }
        }
        let ids = try found
            .filter { $0.url.path.contains("/api/get_members") }
            .flatMap { try GetMembersRequest(serializedBytes: $0.body ?? Data()).memberIds.map(\.userID.id) }
        #expect(ids.contains("u-sender"))
    }
}
