import ChatKit
import Foundation
import Testing
@testable import AppCore

/// Spec §6.2 - the login window cannot be reached with a previous account's
/// data still in the store.
///
/// Session 15 §2 is why this exists: the erase was originally tied to the Sign
/// Out menu command, which is the *least* likely route to a different account
/// signing in. The likeliest is the nine-day `COMPASS` fuse expiring, and that
/// path never erased. The guarantee is now "every entry into `.needsSignIn`
/// erases first", and these tests are what stop it decaying back into a
/// convention.
@MainActor
struct SignOutAndEraseTests {
    private let space = Conversation.ID("space/1")

    private func conversation() -> Conversation {
        Conversation(id: space, kind: .space, title: "Support", lastActivity: nil, members: [])
    }

    /// A row that must not survive into the next account's session.
    private func seed(_ services: FakeLaunchServices) throws {
        try services.store.apply([.replaceConversations([conversation()])])
        #expect(try services.store.conversations().count == 1)
    }

    @Test func signingOutForgetsTheCredentialAndErasesTheStore() async throws {
        let driver = RecordingDemoDriver()
        let services = try FakeLaunchServices(driver: driver)
        let environment = AppEnvironment(services: services)
        await environment.start()
        try seed(services)

        await environment.signOut()

        #expect(services.calls.contains(.forgetStoredSession))
        #expect(try services.store.conversations().isEmpty)
        #expect(driver.stopCount == 1)
        if case .needsSignIn = environment.phase {} else {
            Issue.record("expected .needsSignIn after signOut")
        }
    }

    /// The ordering guarantee, stated in prose in session 15 and unenforced
    /// until now. If forgetting the credential fails, nothing may be erased:
    /// erasing first would strand someone with a live session, no local data,
    /// and no way to sign out of it.
    @Test func aFailureToForgetTheCredentialErasesNothing() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        try seed(services)
        services.forgetFailure = ChatError.unknown("the Keychain refused")

        await environment.signOut()

        #expect(try services.store.conversations().count == 1)
        guard case .failed = environment.phase else {
            Issue.record("expected .failed, not a login window over a live session")
            return
        }
    }

    /// The fuse path. `start()` observing `.notAuthenticated` is the
    /// commonest route to a different account signing in, and session 15 found
    /// it did not erase.
    ///
    /// Note on the shape: an earlier draft of this test called `signOut()`
    /// first and then `signedIn()`, which was **vacuous** - the `signOut()`
    /// had already erased the store, so the closing assertion passed without
    /// the `.notAuthenticated` path running at all. Ruling R3 in the SDD
    /// ledger. Seed, fail the connect, launch once.
    @Test func aSessionGoogleRejectedErasesBeforeAskingForAnother() async throws {
        let services = try FakeLaunchServices()
        // A previous account's row, present before this launch begins.
        try services.store.apply([.replaceConversations([conversation()])])
        services.backend.connectFailure = ChatError.notAuthenticated
        let environment = AppEnvironment(services: services)

        await environment.start()

        #expect(try services.store.conversations().isEmpty)
        guard case let .needsSignIn(reason) = environment.phase else {
            Issue.record("expected .needsSignIn after a rejected session")
            return
        }
        #expect(reason == "Your Google session stopped working. Sign in again.")
    }

    /// Waits, bounded, for `requestSignIn()`'s hand-off to leave the `.failed`
    /// it started from. A fixed 50 ms wait lost that race about one run in
    /// twelve under the full suite's load, where the escape took over 100 ms
    /// against 2.5 ms alone (session 53).
    private func waitForEscape(from failure: String, in environment: AppEnvironment) async throws {
        for _ in 0 ..< 2000 {
            guard case let .failed(message) = environment.phase, message == failure else { return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func theEscapeFromAFailedLaunchAlsoErases() async throws {
        let services = try FakeLaunchServices()
        services.makeSessionFailure = ChatError.unknown("no session in the Keychain")
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case let .failed(failure) = environment.phase else {
            Issue.record("expected .failed to set the test up")
            return
        }
        try seed(services)

        environment.requestSignIn()
        // `requestSignIn()` is synchronous because SwiftUI's Button needs it
        // to be, and hands off to a Task. Wait for that Task to finish.
        try await waitForEscape(from: failure, in: environment)

        #expect(try services.store.conversations().isEmpty)
        guard case let .needsSignIn(reason) = environment.phase else {
            Issue.record("expected .needsSignIn, got something else")
            return
        }
        // The failure itself is carried forward, so the capture window says
        // what went wrong rather than implying the person did something.
        #expect(reason?.contains("no session in the Keychain") == true)
    }

    @Test func requestingASignInFromAnyOtherPhaseDoesNothing() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        try seed(services)

        environment.requestSignIn()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        // A running session must not be torn down by a control that is only
        // meant to rescue a failed launch.
        #expect(try services.store.conversations().count == 1)
        guard case .running = environment.phase else {
            Issue.record("a running session should still be running")
            return
        }
    }

    /// The erase has to go through the session that is still running, not
    /// around it.
    ///
    /// `SyncEngine.start()` assigns its consuming `Task` *before*
    /// `backend.connect()`, so a `.notAuthenticated` throw arrives with a live
    /// consumer already draining the backend into the store. Erasing through
    /// `LaunchServices.eraseStore()` at that moment is the interleaving
    /// `ChatSessionModel.stopAndEraseStore()`'s own doc comment describes -
    /// "a write already in flight from this very session land[ing] after the
    /// tables are wiped" - and it opens a second connection to the same file
    /// as well, since that method exists for when there is "no live model to
    /// ask".
    ///
    /// **Why these three assertions and not a reproduction of the race.**
    /// Racing the consumer would be flaky, so the observable guarantee is
    /// asserted instead, at two seams the fix does not own: the store ended up
    /// empty (the erase happened at all), the *backend* was disconnected
    /// exactly once (the session was stopped - `SyncEngine.stop()` is
    /// `disconnect()`'s only caller), and `LaunchServices.eraseStore()` was
    /// never reached (so the erase went through the live model's own
    /// connection). Nothing here reads a flag the fix sets. That the stop
    /// precedes the wipe *inside* `stopAndEraseStore()` is that method's own
    /// guarantee and already has its own test -
    /// `SyncEngineTests.ChatSessionModelTeardownTests` - which is why this
    /// asserts which door was used rather than re-asserting the ordering
    /// behind it.
    @Test func aRejectedSessionIsErasedThroughItsOwnModelNotASecondConnection() async throws {
        let services = try FakeLaunchServices()
        // A previous account's row, present before this launch begins.
        try services.store.apply([.replaceConversations([conversation()])])
        services.backend.connectFailure = ChatError.notAuthenticated
        let environment = AppEnvironment(services: services)

        await environment.start()

        #expect(try services.store.conversations().isEmpty)
        #expect(services.backend.disconnectCount == 1)
        #expect(!services.calls.contains(.eraseStore))
    }

    /// The second path that built a model and lost it: `startDiagnostics()`
    /// throwing *after* `phase = .running(model)` was set. That still lands on
    /// `.failed` - a diagnostic that will not start is a failure, not a
    /// sign-in problem - and the fully connected session it leaves behind is
    /// what the escape from `.failed` has to erase through.
    ///
    /// `FakeLaunchServices` carried failure knobs for five operations and not
    /// for this one, which is why nothing could reach this state.
    @Test func aFailedDiagnosticStillErasesThroughTheSessionItBuilt() async throws {
        let services = try FakeLaunchServices(
            arguments: LaunchArguments(runsDiagnostics: true)
        )
        services.startDiagnosticsFailure = ChatError.unknown("the App Nap probe refused")
        // Longer than the old fixed 50 ms wait, as the full suite's load can make it.
        services.backend.disconnectDelay = .milliseconds(150)
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case let .failed(failure) = environment.phase else {
            Issue.record("a diagnostic that would not start must land on .failed")
            return
        }
        // Deliberate, and recorded so a future change to it is a decision
        // rather than a surprise: `.failed` does not tear the session down. A
        // diagnostic refusing to start must not disconnect a working Chat
        // session, and the escape below is what stops it.
        #expect(services.backend.disconnectCount == 0)
        try seed(services)

        environment.requestSignIn()
        // `requestSignIn()` is synchronous because SwiftUI's Button needs it
        // to be, and hands off to a Task. Wait for that Task to finish.
        try await waitForEscape(from: failure, in: environment)

        #expect(try services.store.conversations().isEmpty)
        #expect(services.backend.disconnectCount == 1)
        #expect(!services.calls.contains(.eraseStore))
        guard case .needsSignIn = environment.phase else {
            Issue.record("expected .needsSignIn after the escape from .failed")
            return
        }
    }

    /// Two scenes (the main window and the Settings window) each carry their
    /// own sign-out confirmation, so both can be confirmed before either
    /// finishes. `FakeLaunchServices.forgetStoredSession()` yields once before
    /// recording precisely so this race is reachable rather than theoretical.
    @Test func signOutCannotRunTwiceAtOnce() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        try seed(services)

        async let first: Void = environment.signOut()
        async let second: Void = environment.signOut()
        _ = await (first, second)

        #expect(services.calls.filter { $0 == .forgetStoredSession }.count == 1)
    }

    @Test func anEraseThatFailsShowsTheFailureRatherThanALoginWindow() async throws {
        let services = try FakeLaunchServices()
        services.storedSessionExists = false
        services.eraseFailure = ChatError.unknown("the database is locked")
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case let .failed(message) = environment.phase else {
            Issue.record("expected .failed when the erase could not be proven")
            return
        }
        #expect(message.contains("the database is locked"))
    }
}
