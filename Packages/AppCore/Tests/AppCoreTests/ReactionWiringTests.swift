import ChatKit
import Foundation
import Testing
@testable import AppCore

/// `ChatSceneActions.reactions` exists only while a session runs on a backend
/// that can react (`CLAUDE.md`: never draw a control the seam cannot honour).
@MainActor
struct ReactionWiringTests {
    private func running(canReact: Bool) async throws -> AppEnvironment {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, canReact: canReact)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return environment
        }
        return environment
    }

    @Test func withoutTheCapabilityNoReactionActionIsOffered() async throws {
        let environment = try await running(canReact: false)
        #expect(environment.actions.reactions == nil)
    }

    @Test func withTheCapabilityTheActionIsOffered() async throws {
        let environment = try await running(canReact: true)
        #expect(environment.actions.reactions != nil)
    }
}
