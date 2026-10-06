import ChatKit
import Foundation
import Testing
@testable import AppCore

/// `ChatSceneActions.messages` exists only while a session runs on a backend
/// that can edit or delete (edit spec §5).
@MainActor
struct MessageActionsWiringTests {
    private func running(canEdit: Bool, canDelete: Bool) async throws -> AppEnvironment {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(
                canSendMessages: true, canEditMessages: canEdit, canDeleteMessages: canDelete
            )
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return environment
        }
        return environment
    }

    @Test func withNeitherCapabilityNoActionIsOffered() async throws {
        let environment = try await running(canEdit: false, canDelete: false)
        #expect(environment.actions.messages == nil)
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func withEitherCapabilityTheActionsAreOffered(_ canEdit: Bool, _ canDelete: Bool) async throws {
        let environment = try await running(canEdit: canEdit, canDelete: canDelete)
        #expect(environment.actions.messages != nil)
    }
}
