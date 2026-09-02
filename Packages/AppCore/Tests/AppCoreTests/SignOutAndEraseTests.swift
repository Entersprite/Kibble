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

    @Test func theEscapeFromAFailedLaunchAlsoErases() async throws {
        let services = try FakeLaunchServices()
        services.makeSessionFailure = ChatError.unknown("no session in the Keychain")
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .failed = environment.phase else {
            Issue.record("expected .failed to set the test up")
            return
        }
        try seed(services)

        environment.requestSignIn()
        // `requestSignIn()` is synchronous because SwiftUI's Button needs it
        // to be, and hands off to a Task. Give that Task a turn.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

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
