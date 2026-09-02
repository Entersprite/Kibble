import AppCore
import Foundation
import Testing
@testable import MacHost

/// Spec §6.4 item 32 - the one piece of real logic in `SystemLaunchServices`.
///
/// Session 13 §2.1 is why it exists: a single file shared between the fixture
/// and the real bridge put a fixture's invented conversations on screen during
/// a real session, indistinguishable from real ones, because by then nothing
/// on screen remembered where a row came from. That is not a stale cache; it
/// is fabricated data presented as a person's actual chats, and it was
/// observed happening.
///
/// `@MainActor`: `SystemLaunchServices` is main-actor isolated (it conforms
/// `LaunchServices`, which is), and that isolation reaches its static members
/// too. Same pattern as `AppCoreTests`' `LaunchDecisionTests` and
/// `SceneMappingTests`.
@MainActor
struct DatabasePathTests {
    @Test func theFixtureAndTheRealBridgeNeverShareAFile() {
        let real = SystemLaunchServices.databaseName(
            for: LaunchArguments(usesRealBackend: true)
        )
        let fixture = SystemLaunchServices.databaseName(
            for: LaunchArguments(usesRealBackend: false)
        )

        #expect(real == "chat-local.sqlite")
        #expect(fixture == "chat-fixture.sqlite")
        #expect(real != fixture)
    }
}
