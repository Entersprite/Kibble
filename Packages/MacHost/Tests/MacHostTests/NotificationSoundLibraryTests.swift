import AVFoundation
import ChatKit
import Foundation
import Testing
@testable import MacHost

struct NotificationSoundLibraryTests {
    @Test func importsACopyAsSystemPlayablePCMAndRetainsItWithoutTheOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Soft Chime.aif")
        try FileManager.default.copyItem(at: #require(AppSound.newMessage.url), to: source)
        let directory = root.appendingPathComponent("kept")
        let choice = try NotificationSoundLibrary.importFile(source, directory: directory)
        try FileManager.default.removeItem(at: source)
        let filename = try #require(NotificationSoundLibrary.filename(for: choice))
        let kept = try AVAudioFile(forReading: directory.appendingPathComponent(filename))
        #expect(choice.name == "Soft Chime")
        #expect(kept.length > 0)
        #expect(kept.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM)
        let library = root.appendingPathComponent("Library")
        try MessageNotificationSound.install(
            source: directory.appendingPathComponent(filename),
            library: library,
            filename: filename
        )
        #expect(try Data(contentsOf: library.appendingPathComponent("Sounds/" + filename))
            == Data(contentsOf: directory.appendingPathComponent(filename)))
    }

    @Test func thirtySecondFilesAreRefusedBeforeKeepingACopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("long.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = 240_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 240_000)
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let directory = root.appendingPathComponent("kept")
        #expect(throws: (any Error).self) { try NotificationSoundLibrary.importFile(
            source,
            directory: directory
        ) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func copiedSoundsRemainSelectableAfterReopeningAndRejectPathIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sound = NotificationSound(id: UUID().uuidString, name: "Chime")
        _ = try NotificationSoundLibrary.remember(sound, in: directory, previous: [])
        #expect(try NotificationSoundLibrary.loadCustomSounds(in: directory) == [sound])
        let invalid = NotificationSound(id: "../outside", name: "Unsafe")
        _ = try NotificationSoundLibrary.remember(invalid, in: directory, previous: [sound, sound])
        #expect(try NotificationSoundLibrary.loadCustomSounds(in: directory) == [sound])
    }

    @Test func customIdentifiersCannotBecomePaths() {
        #expect(NotificationSoundLibrary.filename(for: .init(id: "../outside", name: "Unsafe")) == nil)
        #expect(NotificationSoundLibrary.filename(for: .system) == nil)
        #expect(NotificationSoundLibrary.filename(for: .kibble) == nil)
    }
}
