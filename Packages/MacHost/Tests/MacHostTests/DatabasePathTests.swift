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

    /// The same rule for pictures: a fixture's image cached under the real
    /// bridge's directory would show in a real conversation's bubble.
    @Test func theFixtureAndTheRealBridgeNeverShareAnAttachmentCache() {
        let real = SystemLaunchServices.attachmentDirectoryName(for: LaunchArguments(usesRealBackend: true))
        let fixture = SystemLaunchServices
            .attachmentDirectoryName(for: LaunchArguments(usesRealBackend: false))
        #expect(real == "attachments-local")
        #expect(fixture == "attachments-fixture")
    }

    /// The no-session sign-out path's half of the erase (`LaunchServices
    /// .eraseStore()`). Tested through the helper, against a temporary
    /// directory, because `eraseStore()` itself also opens the real store.
    @Test func theAttachmentDirectoryIsRemovedWithEverythingInIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "machost-attachments-\(UUID().uuidString)/attachments-local",
                directoryHint: .isDirectory
            )
        let entry = directory.appending(path: "entry", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: entry.appending(path: "Screen Shot 1.png"))

        try SystemLaunchServices.removeAttachmentDirectory(directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    /// Erasing what was never written is the commonest case, and not an error.
    @Test func aMissingAttachmentDirectoryIsNotAnError() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "never-\(UUID().uuidString)")
        try SystemLaunchServices.removeAttachmentDirectory(missing)
        try SystemLaunchServices.removeAttachmentDirectory(nil)
    }
}
