import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Everything `searchMessages(_:after:)` refuses rather than guesses at: a
/// filter never captured on the wire, a conversation whose shape was never
/// captured, a cursor that does not decode or belongs to another query, a
/// shell too thin for `batchexecute`, and no connection at all.
@Suite(.timeLimit(.minutes(1)))
struct SearchMessagesRefusalTests {
    @Test func mentionsMeWithNoResolvedIdentityThrowsAClearError() async throws {
        let transport = SearchTransport(
            shell: SearchFixtures.fullShell(), selfStatus: .failure(SearchTransport.NoStream())
        )
        let backend = try await SearchBackendSupport.connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(MessageSearchQuery(text: "x", mentionsMe: true), after: nil)
        }
    }

    @Test func saidInADirectMessageIsRefused() async throws {
        let transport = SearchTransport(shell: SearchFixtures.fullShell())
        let backend = try await SearchBackendSupport.connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(
                MessageSearchQuery(text: "x", conversation: Conversation.ID("dm/d-1")), after: nil
            )
        }
        #expect(await SearchBackendSupport.batchRequests(transport).isEmpty)
    }

    @Test func newerThanIsRefusedRatherThanIgnored() async throws {
        let transport = SearchTransport(shell: SearchFixtures.fullShell())
        let backend = try await SearchBackendSupport.connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(
                MessageSearchQuery(text: "x", newerThan: Date()), after: nil
            )
        }
        #expect(await SearchBackendSupport.batchRequests(transport).isEmpty)
    }

    @Test func aCursorThatDoesNotDecodeIsRefused() async throws {
        let transport = SearchTransport(shell: SearchFixtures.fullShell())
        let backend = try await SearchBackendSupport.connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(
                MessageSearchQuery(text: "x"), after: MessageSearchCursor("not a cursor")
            )
        }
        #expect(await SearchBackendSupport.batchRequests(transport).isEmpty)
    }

    @Test func aCursorFromADifferentQueryIsRefused() async throws {
        let inner = SearchFixtures.pageInner(nextToken: "tok-1", hits: [])
        let transport = try SearchTransport(shell: SearchFixtures.fullShell(), batchResponses: [
            SearchFixtures.ok(SearchFixtures.answerBody(inner: inner))
        ])
        let backend = try await SearchBackendSupport.connected(transport)
        let queryA = MessageSearchQuery(text: "a")
        let queryB = MessageSearchQuery(text: "b")
        let page1 = try await backend.searchMessages(queryA, after: nil)
        let cursor = try #require(page1.next)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(queryB, after: cursor)
        }
    }

    @Test func aShellMissingTheBatchKeysThrowsAClearError() async throws {
        // `LocalBridgeBackendTests.shell(app:)` predates search and carries
        // no `SNlM0e`/`FdrFJe`.
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        let transport = SearchTransport(
            shell: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
        )
        let backend = try await SearchBackendSupport.connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(MessageSearchQuery(text: "x"), after: nil)
        }
        #expect(await SearchBackendSupport.batchRequests(transport).isEmpty)
    }

    @Test func notConnectedThrows() async throws {
        let transport = SearchTransport(shell: SearchFixtures.fullShell())
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(MessageSearchQuery(text: "x"), after: nil)
        }
    }
}
