import ChatKit
import Foundation
import Testing
@testable import AppCore

/// The status menu's actions exist only while a session runs on a backend
/// that can set status (`CLAUDE.md`: never draw a control the seam cannot honour).
@MainActor
struct StatusWiringTests {
    private func running(canSetStatus: Bool) async throws -> AppEnvironment {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, canSetStatus: canSetStatus)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return environment
        }
        return environment
    }

    @Test func withoutTheCapabilityNoStatusActionIsOffered() async throws {
        let environment = try await running(canSetStatus: false)
        #expect(environment.actions.setStatus == nil)
        #expect(environment.actions.setAvailability == nil)
    }

    @Test func withTheCapabilityBothAreOffered() async throws {
        let environment = try await running(canSetStatus: true)
        #expect(environment.actions.setStatus != nil)
        #expect(environment.actions.setAvailability != nil)
    }
}
