import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// Ghost mode: what this client refuses to publish about itself.
///
/// Enforced at one place - `SyncEngine.submit(_:)` - behind an **exhaustive**
/// switch, so a new privacy-relevant `ChatCommand` stops the package
/// compiling until someone decides which side of the line it is on. That
/// compile error is the entire point of the design; a two-case `if` would let
/// the next such command leak by default.
///
/// Ghost mode is deliberately **not** a backend concern, and the limit that
/// follows is written down rather than hidden: the initial `PingEvent` this
/// app sends on every registration carries `application_focus_state:
/// FOCUS_STATE_FOREGROUND` and `client_interactive_state: INTERACTIVE`
/// (`findings.md` §29). `[Verify]` what Google renders from those, but a
/// client-side flag cannot suppress them. Ghost mode covers read state and
/// typing, and says so.
@MainActor
struct GhostModeTests {
    private func harness() async throws -> (SyncEngine, RecordingBackend) {
        let backend = RecordingBackend()
        let engine = try SyncEngine(backend: backend, store: ChatStore.inMemory())
        // `FakeBackend.send(_:)` throws `.transport("not connected")` unless
        // `connect()` has run - true of every real backend too, so a test
        // that never starts the engine cannot exercise `submit(_:)` at all.
        try await engine.start()
        return (engine, backend)
    }

    @Test func ghostModeSuppressesMarkRead() async throws {
        let (engine, backend) = try await harness()
        await engine.setGhostMode(true)

        let submitted = await engine.submit(.markRead(
            conversationID: Conversation.ID("space:1"),
            upTo: Date(timeIntervalSince1970: 1)
        ))

        #expect(submitted == false)
        #expect(await backend.commands.isEmpty)
    }

    @Test func ghostModeSuppressesTypingState() async throws {
        let (engine, backend) = try await harness()
        await engine.setGhostMode(true)

        let submitted = await engine.submit(.setTyping(
            conversationID: Conversation.ID("space:1"),
            threadID: nil,
            isTyping: true
        ))

        #expect(submitted == false)
        #expect(await backend.commands.isEmpty)
    }

    /// Reporting activity publishes presence, which is what ghosting withholds
    /// (active-presence spec §2).
    @Test func ghostModeSuppressesActivity() async throws {
        let (engine, backend) = try await harness()
        await engine.setGhostMode(true)

        let submitted = await engine.submit(.reportActivity(active: true))

        #expect(submitted == false)
        #expect(await backend.commands.isEmpty)
    }

    /// Ghosting hides what you have read, not what you have said.
    @Test func ghostModeDoesNotSuppressSending() async throws {
        let (engine, backend) = try await harness()
        await engine.setGhostMode(true)

        let submitted = await engine.submit(.sendMessage(
            conversationID: Conversation.ID("space:1"),
            threadID: nil,
            text: "hello",
            localID: "local-1"
        ))

        #expect(submitted)
        #expect(await backend.commands.count == 1)
    }

    @Test func markReadPassesWhenNotGhosting() async throws {
        let (engine, backend) = try await harness()

        let submitted = await engine.submit(.markRead(
            conversationID: Conversation.ID("space:1"),
            upTo: Date(timeIntervalSince1970: 1)
        ))

        #expect(submitted)
        #expect(await backend.commands.count == 1)
    }

    /// A backend that throws is not a suppression, and the difference has to
    /// be visible to the caller: the auto-mark watermark advances only on a
    /// real success, so a `false` that means "it failed" and a `false` that
    /// means "we never sent it" both correctly leave it where it was.
    @Test func aFailedSubmitReportsFalse() async throws {
        let (engine, backend) = try await harness()
        await backend.failSubmissions(true)

        let submitted = await engine.submit(.markRead(
            conversationID: Conversation.ID("space:1"),
            upTo: Date(timeIntervalSince1970: 1)
        ))

        #expect(submitted == false)
    }
}
