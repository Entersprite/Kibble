import ChatKit
import Foundation
import SyncEngine
import Testing
@testable import AppCore

/// The coordinator across a session's life: a click that arrives before the
/// session can act on it, and the end of a session with work still in flight.
@MainActor
struct NotificationCoordinatorLifecycleTests {
    private let dm = Conversation.ID("dm/1")

    /// The click that launched the app is replayed once the session has
    /// connected, not the moment it is attached: a "Mark as Read" submitted
    /// while `connect()` is still running is lost. `.open` takes the same
    /// replay path and is observable without the mark's two-second wait.
    @Test func aLaunchingClickIsReplayedOnlyOnceTheSessionHasConnected() async throws {
        let services = try FakeLaunchServices()
        services.backend.holdConnect()
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        delivery.respond.yield(.open(dm))
        // No session yet: the click asks for the window once, and waits.
        #expect(await eventually { environment.windowRequests == 1 })

        let starting = Task { await environment.start() }
        #expect(await eventually { services.backend.connectEntered })
        // Attached and still connecting: nothing replayed yet.
        #expect(environment.windowRequests == 1)

        services.backend.releaseConnect()
        await starting.value
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        #expect(model.selected == dm)
        #expect(environment.windowRequests == 2)
    }
}
