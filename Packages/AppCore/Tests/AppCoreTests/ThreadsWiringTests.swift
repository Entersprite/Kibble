import ChatKit
import Foundation
import Testing
@testable import AppCore

/// The thread actions exist only while a session runs on a backend that has
/// threads (`CLAUDE.md`: never draw a control the seam cannot honor).
@MainActor
struct ThreadsWiringTests {
    private func running(supportsThreads: Bool) async throws -> AppEnvironment {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, supportsThreads: supportsThreads)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return environment
        }
        return environment
    }

    @Test func withoutTheCapabilityNoThreadActionIsOffered() async throws {
        let environment = try await running(supportsThreads: false)
        #expect(environment.actions.threads == nil)
    }

    @Test func withTheCapabilityTheyAre() async throws {
        let environment = try await running(supportsThreads: true)
        #expect(environment.actions.threads != nil)
    }

    /// Before any thread is opened the scene has no panel and an empty list.
    @Test func aFreshSceneHasNoPanel() async throws {
        let environment = try await running(supportsThreads: true)
        #expect(environment.sceneState.threads.panel == nil)
        #expect(environment.sceneState.threads.showingList == false)
    }
}
