import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// What the in-process bridge can do today, and - more importantly - what it
/// says when asked for what it cannot.
@Suite(.timeLimit(.minutes(1)))
struct LocalBridgeBackendTests {
    static func shell(app: String) -> String {
        """
        <script nonce="x">window.WIZ_global_data = ({"qwAQke":"\(app)",\
        "SMqcke":"\(String(repeating: "t", count: 42))","cfb2h":"boq_x"});</script>
        """
    }

    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private func backend(_ responses: [Result<HTTPResponse, any Error>]) -> LocalBridgeBackend {
        LocalBridgeBackend(cookies: Self.cookies, transport: ScriptedTransport(responses))
    }

    private func collect(_ backend: LocalBridgeBackend, _ count: Int) async -> [ChatEvent] {
        var iterator = backend.events.makeAsyncIterator()
        var events: [ChatEvent] = []
        for _ in 0 ..< count {
            guard let event = await iterator.next() else { break }
            events.append(event)
        }
        return events
    }

    // MARK: - Connecting

    @Test func aSignedInShellConnects() async throws {
        let backend = backend([ScriptedTransport.ok(Self.shell(app: "DynamiteWebUi"))])
        async let events = collect(backend, 2)

        try await backend.connect()

        #expect(await events == [
            .connectionStateChanged(.connecting),
            .connectionStateChanged(.connected)
        ])
    }

    /// Chat answers a stale session with **HTTP 200** and its own sign-in
    /// shell, so the status tells you nothing. This is the one case the whole
    /// `WizGlobalData` parser exists for.
    @Test func aSignInShellIsReportedAsNotAuthenticated() async throws {
        let backend = backend([ScriptedTransport.ok(Self.shell(app: "AccountsSignInUi"))])
        async let events = collect(backend, 3)

        await #expect(throws: ChatError.notAuthenticated) {
            try await backend.connect()
        }

        // Emitted as well as thrown: a UI reads the store, and would otherwise
        // never learn why nothing is syncing.
        let seen = await events
        #expect(seen.contains(.backendError(.notAuthenticated)))
        #expect(seen.contains(.connectionStateChanged(.disconnected(reason: "not signed in"))))
    }

    @Test func aBounceToTheAccountsHostIsAlsoNotAuthenticated() async throws {
        let backend = try backend([
            ScriptedTransport.ok(
                "<html>sign in</html>",
                url: #require(URL(string: "https://accounts.google.com/signin"))
            )
        ])
        await #expect(throws: ChatError.notAuthenticated) {
            try await backend.connect()
        }
    }

    /// Not a credentials problem. Reporting it as one sent a previous session
    /// chasing three unnecessary cookie captures.
    @Test func aRejectedClientIsNotReportedAsBadCredentials() async throws {
        let url = try #require(URL(string: "https://chat.google.com/u/0/error/browser-not-supported"))
        let backend = backend([ScriptedTransport.ok("<title>Chat: Unsupported Browser</title>", url: url)])

        await #expect(throws: ChatError.self) {
            try await backend.connect()
        }
        let error = await backend.lastFailure
        #expect(error != .notAuthenticated)
        #expect(String(describing: error).lowercased().contains("browser"))
    }

    @Test func aTransportFailureIsReportedAsTransport() async throws {
        struct Boom: Error {}
        let backend = backend([.failure(Boom())])
        await #expect(throws: ChatError.self) {
            try await backend.connect()
        }
        if case .transport = await backend.lastFailure { } else {
            await Issue.record("expected .transport, got \(String(describing: backend.lastFailure))")
        }
    }

    // MARK: - Honest capabilities

    /// Every flag is false until a channel exists. That is not modesty: the UI
    /// reads capabilities to decide what to offer, and a bridge that claimed it
    /// could send would give the user a composer that silently fails.
    @Test func itAdvertisesNothingItCannotYetDo() {
        let backend = backend([])
        #expect(backend.capabilities == Capabilities())
    }

    @Test func everyActionSaysWhatIsMissingRatherThanFailingVaguely() async throws {
        let backend = backend([ScriptedTransport.ok(Self.shell(app: "DynamiteWebUi"))])
        try await backend.connect()

        await #expect(throws: ChatError.unsupported(capability: LocalBridgeBackend.missingChannel)) {
            _ = try await backend.loadConversations()
        }
        await #expect(throws: ChatError.unsupported(capability: LocalBridgeBackend.missingChannel)) {
            _ = try await backend.loadMessages(in: Conversation.ID("space:1"), before: nil)
        }
        await #expect(throws: ChatError.unsupported(capability: LocalBridgeBackend.missingChannel)) {
            try await backend.send(.deleteMessage(id: Message.ID("m")))
        }
        await #expect(throws: ChatError.unsupported(capability: LocalBridgeBackend.missingChannel)) {
            try await backend.setNotificationSetting(.less, for: Conversation.ID("space:1"))
        }
    }

    @Test func disconnectingSaysSoAndLeavesTheStreamOpen() async throws {
        let backend = backend([ScriptedTransport.ok(Self.shell(app: "DynamiteWebUi"))])
        var iterator = backend.events.makeAsyncIterator()
        try await backend.connect()
        _ = await iterator.next()
        _ = await iterator.next()

        await backend.disconnect()

        #expect(await iterator.next() == .connectionStateChanged(.disconnected(reason: nil)))
    }
}
