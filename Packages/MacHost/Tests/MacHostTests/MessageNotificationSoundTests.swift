import Foundation
import Testing
@testable import MacHost

struct MessageNotificationSoundTests {
    @Test func installationPreservesTheSuppliedCueAndRefreshesAnOlderCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library with spaces")
        let source = try #require(AppSound.newMessage.url)
        try MessageNotificationSound.install(source: source, library: library)
        let sounds = library.appendingPathComponent("Sounds")
        let installed = sounds.appendingPathComponent("Kibble-Message-1.aiff")
        let expected = try Data(contentsOf: source)
        #expect(try Data(contentsOf: installed) == expected)
        let unrelated = sounds.appendingPathComponent("Personal.aif")
        try Data("retained".utf8).write(to: unrelated)
        try Data("old cue".utf8).write(to: installed)
        try MessageNotificationSound.install(source: source, library: library)
        #expect(try Data(contentsOf: installed) == expected)
        #expect(try Data(contentsOf: unrelated) == Data("retained".utf8))
        let modified = try installed.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        try MessageNotificationSound.install(source: source, library: library)
        #expect(try installed.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate == modified)
    }

    @Test func aMissingSourceCannotReplaceTheInstalledCue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(AppSound.newMessage.url)
        try MessageNotificationSound.install(source: source, library: root)
        let installed = root.appendingPathComponent("Sounds/Kibble-Message-1.aiff")
        let original = try Data(contentsOf: installed)
        #expect(throws: (any Error).self) {
            try MessageNotificationSound.install(
                source: root.appendingPathComponent("missing"),
                library: root
            )
        }
        #expect(try Data(contentsOf: installed) == original)
    }

    @Test func anUnexpectedSoundsLinkIsPreservedAndNeverWrittenThrough() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let shared = root.appendingPathComponent("Personal Sounds")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let sounds = library.appendingPathComponent("Sounds")
        try FileManager.default.createSymbolicLink(at: sounds, withDestinationURL: shared)
        let source = try #require(AppSound.newMessage.url)
        #expect(throws: (any Error).self) {
            try MessageNotificationSound.install(source: source, library: library)
        }
        #expect(try sounds.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath:
            shared.path(percentEncoded: false)).isEmpty)
    }
}
