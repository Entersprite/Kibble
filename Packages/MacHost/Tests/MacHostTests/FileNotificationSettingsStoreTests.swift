import AppCore
import ChatKit
import Foundation
import Testing
@testable import MacHost

struct FileNotificationSettingsStoreTests {
    private let alice = Member.ID("users/alice")
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "gchat-settings-\(UUID())",
            isDirectory: true
        )
    }

    private func sample() -> NotificationSettings {
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(delivery: .off), for: .section(.spaces), at: at, by: "mac")
        return settings
    }

    @Test func settingsRoundTripAndAMissingFileIsNil() throws {
        let store = FileNotificationSettingsStore(directory: directory())
        #expect(try store.load(for: alice) == nil)
        try store.save(sample(), for: alice)
        #expect(try store.load(for: alice) == sample())
    }

    /// Review Focus 2.
    @Test func idsThatDifferOnlyInEscapedCharactersNeverShareAFile() throws {
        let store = FileNotificationSettingsStore(directory: directory())
        let slashed = Member.ID("users/1")
        let escaped = Member.ID("users%2F1")
        #expect(FileNotificationSettingsStore.fileName(for: slashed) != FileNotificationSettingsStore
            .fileName(for: escaped))
        try store.save(sample(), for: slashed)
        #expect(try store.load(for: escaped) == nil)
    }

    @Test func theDeviceIDIsStableAcrossInstances() throws {
        let place = directory()
        let first = try FileNotificationSettingsStore(directory: place).deviceID()
        let second = try FileNotificationSettingsStore(directory: place).deviceID()
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    /// Review Focus 1: an unreadable file throws once, is moved aside rather
    /// than left for the next save to overwrite, and the next load is clean.
    @Test func anUnreadableFileIsMovedAsideAndReported() throws {
        let place = directory()
        let store = FileNotificationSettingsStore(directory: place)
        try store.save(sample(), for: alice)
        let file = place
            .appendingPathComponent("notification-settings", isDirectory: true)
            .appendingPathComponent(FileNotificationSettingsStore.fileName(for: alice))
        try Data("{ not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.load(for: alice) }
        #expect(try store.load(for: alice) == nil)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(leftovers.contains { $0.contains("corrupt") })
    }

    /// A file that cannot be read at all, not only one that does not decode,
    /// is moved aside too. After a load failure the model saves a
    /// receipts-off record straight away, and that save must not replace a
    /// file whose contents may still be recoverable.
    @Test func aFileThatCannotBeReadIsMovedAsideToo() throws {
        let place = directory()
        let store = FileNotificationSettingsStore(directory: place)
        try store.save(sample(), for: alice)
        let file = place
            .appendingPathComponent("notification-settings", isDirectory: true)
            .appendingPathComponent(FileNotificationSettingsStore.fileName(for: alice))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)

        #expect(throws: (any Error).self) { try store.load(for: alice) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(leftovers.contains { $0.contains("corrupt") })
    }

    /// Review Focus 1, round 2: two unreadable loads back to back, in the same
    /// second, must not collide on the aside name - the second move must not
    /// silently no-op and leave its corrupt file to be overwritten by the next
    /// save.
    @Test func twoUnreadableLoadsInTheSameSecondEachGetTheirOwnAsideFile() throws {
        let place = directory()
        let store = FileNotificationSettingsStore(directory: place)
        try store.save(sample(), for: alice)
        let file = place
            .appendingPathComponent("notification-settings", isDirectory: true)
            .appendingPathComponent(FileNotificationSettingsStore.fileName(for: alice))

        try Data("{ not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.load(for: alice) }

        try Data("{ still not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.load(for: alice) }

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        let asides = leftovers.filter { $0.contains("corrupt") }
        #expect(asides.count == 2)
        #expect(try store.load(for: alice) == nil)
    }
}
