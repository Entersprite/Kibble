import ChatKit
import Foundation
import Testing
@testable import AppCore

/// Whether the Mac is in use reaches the backend (active-presence spec §5):
/// held while no session runs, sent once one does, and on every change.
@MainActor
struct DeviceActivityWiringTests {
    private func reports(_ services: FakeLaunchServices) -> [Bool] {
        services.backend.sent.compactMap { command in
            if case let .reportActivity(active) = command {
                active
            } else {
                nil
            }
        }
    }

    private func settle(_ services: FakeLaunchServices, until done: ([Bool]) -> Bool) async {
        for _ in 0 ..< 500 where !done(reports(services)) {
            await Task.yield()
        }
    }

    /// Nobody told it otherwise: the app is running, so the Mac is in use.
    @Test func aSessionStartsInUse() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        await settle(services) { !$0.isEmpty }
        #expect(reports(services) == [true])
    }

    @Test func aValueToldBeforeTheSessionIsSentWhenItRuns() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        environment.setDeviceActive(false)
        #expect(reports(services).isEmpty)

        await environment.start()
        await settle(services) { !$0.isEmpty }

        #expect(reports(services) == [false])
    }

    @Test func aChangeWhileRunningIsSent() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        await settle(services) { !$0.isEmpty }

        environment.setDeviceActive(false)
        await settle(services) { $0.count >= 2 }

        #expect(reports(services) == [true, false])
    }
}
