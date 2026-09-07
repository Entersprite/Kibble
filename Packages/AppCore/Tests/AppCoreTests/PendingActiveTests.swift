import ChatKit
import Foundation
import Testing
@testable import AppCore

/// `setActive(_:)` called before `start()` has built a model.
///
/// The real race this pins: the app shell's `.task` reports the frontmost
/// signal concurrently with `environment.start()`, and for the real backend
/// `start()` is a full HTTP shell fetch plus channel registration - seconds,
/// not an instant - so a resign arriving during that window used to be
/// dropped silently (`AppEnvironment.setActive` forwarded straight to
/// `model?.`, and `model` was still `nil`). `ChatSessionModel.isActive`
/// defaults to `true`, so the dropped value left a freshly built model
/// reading frontmost when the app was actually backgrounded.
///
/// Driving the literal concurrent race from a test is not attempted here:
/// `FakeLaunchServices`'s `makeSession()`/`openStore()` return instantly, so
/// there is no window inside `start()` a concurrent `Task` could land a
/// `setActive` call into without an artificial delay this suite has no
/// hook to insert. Instead this drives the reachable half directly - call
/// `setActive` while `phase` is still `.loading` (before `start()` runs at
/// all), which is the same "no model yet" condition the race produces - and
/// asserts on the stored value being applied once a model exists, which is
/// exactly what closes the drop.
@MainActor
struct PendingActiveTests {
    @Test func aValueSetBeforeAModelExistsIsAppliedOnceOneIsBuilt() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)

        // The race: told before `start()` has built anything.
        environment.setActive(false)

        await environment.start()

        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        #expect(!model.isActive)
    }

    /// The positive control: a value told before any model exists still
    /// reaches a *second* model, built by `signedIn()` after a sign-out -
    /// the same doc comment's claim about the entire web-view login window.
    @Test func aValueSetBeforeAModelExistsSurvivesIntoALaterModel() async throws {
        let services = try FakeLaunchServices()
        services.storedSessionExists = false
        let environment = AppEnvironment(services: services)

        environment.setActive(false)
        await environment.start()
        guard case .needsSignIn = environment.phase else {
            Issue.record("expected .needsSignIn to set the test up")
            return
        }

        services.storedSessionExists = true
        await environment.signedIn()

        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running once a credential exists")
            return
        }
        #expect(!model.isActive)
    }
}
