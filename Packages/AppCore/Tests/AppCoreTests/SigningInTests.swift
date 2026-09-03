import ChatKit
import Foundation
import Testing
@testable import AppCore

/// `signedIn()` - the one public entry point the login window calls, and the
/// one that had no test anywhere in the repo.
///
/// Unlike `LaunchDecisionTests` these are not characterization tests: the
/// second and third fail against the code as it shipped, because `signedIn()`
/// set `phase = .loading` unconditionally and so defeated `start()`'s own
/// `if case .running = phase { return }` guard.
///
/// It is reachable twice for one sign-in.
/// `CookieCaptureModel.attemptAutoSave` latches `hasAutoSaved` synchronously,
/// which flips `showsManualControls` to `true` while its own Keychain write is
/// still in flight - so "Save and continue" is clickable during the automatic
/// attempt and both routes call `onSaved()`.
@MainActor
struct SigningInTests {
    /// Sets a launch up in `.needsSignIn` the way a first run reaches it, then
    /// puts a credential where the login window would have put one.
    private func awaitingSignIn() async throws -> (FakeLaunchServices, AppEnvironment) {
        let services = try FakeLaunchServices()
        services.storedSessionExists = false
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .needsSignIn = environment.phase else {
            throw SetupFailure.notAwaitingSignIn
        }
        // What the capture window's `onSaved` implies: the credential is in
        // the store now where a moment ago there was none.
        services.storedSessionExists = true
        return (services, environment)
    }

    private enum SetupFailure: Error {
        case notAwaitingSignIn
    }

    @Test func signingInConnectsRatherThanAskingForARelaunch() async throws {
        let (_, environment) = try await awaitingSignIn()

        await environment.signedIn()

        guard case .running = environment.phase else {
            Issue.record("expected .running once a credential exists")
            return
        }
    }

    /// The double-call the login window can actually produce. Two engines and
    /// two models over one store, the first leaked and never stopped, is what
    /// the missing guard bought.
    @Test func signingInTwiceBuildsOneEngineNotTwo() async throws {
        let (services, environment) = try await awaitingSignIn()

        await environment.signedIn()
        await environment.signedIn()

        #expect(services.calls.count(where: { $0 == .openStore }) == 1)
        #expect(services.calls.count(where: { $0 == .makeSession }) == 1)
        // And the first session is still the live one rather than an
        // orphan: nothing disconnected on the way.
        #expect(services.backend.disconnectCount == 0)
    }

    /// Identity, not just the phase name: a second `signedIn()` that rebuilt
    /// the world would still report `.running`, holding a different model
    /// over a store the first one is still writing to.
    @Test func signingInOverARunningSessionLeavesItAlone() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case let .running(before) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }

        await environment.signedIn()

        guard case let .running(after) = environment.phase else {
            Issue.record("a working session must not be dropped by signedIn()")
            return
        }
        #expect(before === after)
        #expect(!services.calls.contains(.eraseStore))
        #expect(services.backend.disconnectCount == 0)
    }
}
