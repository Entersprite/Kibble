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
        // Not a `BootstrapFailure` or `ClassifiedTransportFailure` - `connect()`
        // throws a plain `ChatError.notAuthenticated` here, so
        // `ConnectionIssueMapping.issue(forConnect:)` has no taxonomy entry for
        // it and honestly says `.unknown` rather than inventing one.
        #expect(
            seen.contains(
                .connectionStateChanged(.disconnected(reason: "not signed in", issue: .unknown("connect")))
            )
        )
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

    @Test func anUnclassifiedTransportFailureUsesGenericCopy() async throws {
        struct Boom: Error { let requestDetail = "private request data" }
        let backend = backend([.failure(Boom())])
        let expected = ChatError.transport("could not reach the service")
        await #expect(throws: expected) {
            try await backend.connect()
        }
        #expect(await backend.lastFailure == expected)
    }

    @Test(arguments: [
        (
            TransportFailureReason.notConnectedToInternet,
            ConnectionIssue.noInternet,
            "not connected to the internet"
        ),
        (
            .other(domain: "NSURLErrorDomain", code: -1000),
            .unknown("NSURLErrorDomain -1000"),
            "could not reach the service"
        )
    ])
    func aClassifiedBootstrapFailureKeepsTheIssueAndReportsReadableCopy(
        reason: TransportFailureReason, issue: ConnectionIssue, message: String
    ) async throws {
        let backend = backend([.failure(ClassifiedTransportFailure(reason))])
        async let events = collect(backend, 3)
        let expected = ChatError.transport(message)

        await #expect(throws: expected) {
            try await backend.connect()
        }

        #expect(await events == [
            .connectionStateChanged(.connecting),
            .connectionStateChanged(.disconnected(reason: "could not reach Chat", issue: issue)),
            .backendError(expected)
        ])
    }

    @Test func retryingBootstrapKeepsUnacknowledgedCheckpointEvents() async throws {
        let backend = backend([
            .failure(ClassifiedTransportFailure(.nameResolution)),
            ScriptedTransport.ok(Self.shell(app: "DynamiteWebUi"))
        ])
        var batches = backend.providerEventBatches.makeAsyncIterator()
        let checkpoint = try GoogleProviderCursor().encoded()
        await #expect(throws: ChatError.transport("could not look up the host")) {
            try await backend.connect(resumingProviderCheckpoint: checkpoint)
        }
        let first = try #require(await batches.next())
        #expect(first.previousCheckpoint == checkpoint)
        #expect(first.events == [.connectionStateChanged(.connecting)])

        try await backend.connect(resumingProviderCheckpoint: checkpoint)
        await backend.acknowledgeProviderBatch(first.id)
        let expected: [ChatEvent] = [
            .connectionStateChanged(.disconnected(reason: "could not reach Chat", issue: .nameResolution)),
            .backendError(.transport("could not look up the host")),
            .connectionStateChanged(.connecting),
            .connectionStateChanged(.connected)
        ]
        var previous = first.checkpoint
        for event in expected {
            let batch = try #require(await batches.next())
            #expect(batch.previousCheckpoint == previous)
            #expect(batch.events == [event])
            previous = batch.checkpoint
            await backend.acknowledgeProviderBatch(batch.id)
        }
        await backend.disconnect()
    }

    // MARK: - Honest capabilities

    /// `canSendMessages` and `supportsThreads` are both true now, and neither
    /// is conditioned on connection state - `canSendMessages` is a fact about
    /// what `send(_:)` implements (`LocalBridgeBackend+Send.swift`),
    /// `supportsThreads` about what `WorldMapping` can compute. `canReact`,
    /// `canMarkRead`, `canFetchAttachments`, `canDownloadFiles` and
    /// `canFetchCustomEmoji` have since joined them, each only once the
    /// backend it names actually worked; the capabilities this test still
    /// leaves `false` are the ones nothing in the backend implements yet.
    /// The UI reads capabilities to decide what to offer, and a bridge that
    /// claimed more would give the user a button that silently fails.
    /// `canFetchAttachments` joined once the fetch worked on the live account
    /// (`findings.md` §51.2), and `canDownloadFiles` once a file download did
    /// (§52.10) - both after a live run. `canFetchCustomEmoji` joined
    /// differently: on a capture of Chat on the web (`findings.md` §54.4),
    /// before any live run from this client. `canSendAttachments` joined on
    /// the two references' agreement, also before a live run: session 50's
    /// `--probe=upload` is what settles it. `canMention` joined on the web
    /// client's capture (`findings.md` §56), before any live run.
    /// `canEditMessages` and `canDeleteMessages` joined on the references
    /// (edit spec §1); `--probe=edit` is what settles them.
    /// `canFetchRemoteImages` joined with `RemoteImageFetch` (links spec §4.4).
    /// `canSetStatus` joined on Chat on the web's bundle and purple
    /// (set-your-status spec §1), before any live run.
    @Test func itAdvertisesSendingAndThreadSupport() {
        let backend = backend([])
        // The observed Threads filter answered successfully but supplied no
        // entries; world and topic events maintain the local followed state.
        #expect(!backend.capabilities.needsFollowedThreadsBackfill)
        #expect(backend.capabilities == Capabilities(
            canSendMessages: true, canEditMessages: true, canDeleteMessages: true, canReact: true,
            canSendTypingState: true, receivesTypingState: true, receivesReadReceipts: true,
            canSetNotificationLevel: true, canSetStatus: true, canMarkRead: true,
            canMarkUnread: true, canHideConversations: true, canBlockConversations: true,
            canLeaveConversations: true, canDeleteConversations: true,
            canCreateConversations: true, canReadConversationDetails: true, canBrowseSpaces: true,
            canOpenDirectConversations: true,
            supportsThreads: true, needsThreadUnreadClearBeforeRead: true,
            canFetchAttachments: true, canDownloadFiles: true, canFetchCustomEmoji: true,
            canSendAttachments: true, maximumAttachmentBytes: 200 * 1024 * 1024,
            canMention: true, canMentionNonMembers: true, needsMentionBackfill: true,
            canFetchRemoteImages: true, canSearchMessages: true,
            messageSearchFilters: [
                .from, .conversation, .olderThan, .newerThan, .hasFile, .hasLink, .mentionsMe, .newestFirst
            ], internalLinkHosts: ["chat.google.com"], extendedFlags: [
                "formattedMessages", "quotedMessages", "cardActions", "forwardMessages",
                "conversationPreview", "customEmojiMessages", "customEmojiStatus",
                "callDiscovery", "conversationWebhooks", "conversationApps", "conversationEmail",
                "messagePins", "starredMessages", "scheduledMessages", "sendScheduledMessageNow",
                "blockedConversations", "blockedPeople", "syncedDraftReads", "syncedDraftWrites",
                "conversationMute",
                "scheduleSavedDraft", "scheduleAttachments", "scheduleForwards",
                "sendSavedDraft", "sendSavedDraftWithAttachments"
            ]
        ))
    }

    @Test func theSpaceLevelWriteRefusesADirectMessage() async throws {
        let backend = backend([ScriptedTransport.ok(Self.shell(app: "DynamiteWebUi"))])
        try await backend.connect()

        await #expect(throws: ChatError.unsupported(capability: "canSetNotificationLevel")) {
            try await backend.setNotificationSetting(.less, for: Conversation.ID("dm/1"))
        }
    }

    // MARK: - loadConversations

    /// Sending a `/api/` request with no verified session and no xsrf token is
    /// not a real attempt - it is one known in advance to fail. This is the
    /// clear failure the task asks for, rather than a request built out of
    /// nothing and shipped anyway.
    @Test func loadConversationsBeforeConnectFailsClearly() async {
        let backend = backend([])
        await #expect(throws: ChatError.self) {
            _ = try await backend.loadConversations()
        }
    }

    @Test func loadConversationsBeforeConnectNamesWhatIsMissing() async throws {
        let backend = backend([])
        do {
            _ = try await backend.loadConversations()
            Issue.record("expected loadConversations() to throw before connect()")
        } catch {
            #expect(String(describing: error).lowercased().contains("connect"))
        }
    }

    @Test func disconnectingSaysSoAndLeavesTheStreamOpen() async throws {
        let backend = backend([ScriptedTransport.ok(Self.shell(app: "DynamiteWebUi"))])
        var iterator = backend.events.makeAsyncIterator()
        try await backend.connect()
        await backend.disconnect()

        // Searched for rather than counted to. This used to drain a fixed two
        // events and then assert on the third, which pinned the exact
        // connect-time sequence - so adding one legitimate event to `connect()`
        // broke a test about `disconnect()`. What this is actually about is
        // that disconnecting says so and does not end the stream.
        var found = false
        for _ in 0 ..< 8 {
            guard let event = await iterator.next() else { break }
            if event == .connectionStateChanged(.disconnected(reason: nil, issue: nil)) {
                found = true
                break
            }
        }
        #expect(found)
    }
}
