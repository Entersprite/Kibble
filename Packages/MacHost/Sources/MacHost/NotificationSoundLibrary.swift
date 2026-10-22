import AppKit
import AVFoundation
import ChatKit
import DesignSystem
import Foundation
import UserNotifications

/// Native sound assets remain local. Policies contain only an opaque UUID and
/// display name, never an external path or a security-scoped bookmark.
public enum NotificationSoundLibrary {
    static let prefix = "Kibble-Notification-"

    @MainActor private static var generation = UUID()
    @MainActor private static var customSounds = loadCustomSounds()
    @MainActor private static let player = RingtonePlayer()

    @MainActor public static var actions: NotificationSoundActions {
        let generation = generation
        return NotificationSoundActions(customSounds: customSounds, importFile: { source in
            guard generation == self.generation else { throw CancellationError() }
            let directory = try directory()
            let sound = try importFile(source, directory: directory)
            customSounds = try remember(sound, in: directory, previous: customSounds)
            return sound
        }, preview: { sound in
            guard generation == self.generation else { return }
            if sound == .system {
                NSSound.beep()
            } else if let url = try? source(for: sound) {
                try? player.play(url, loops: false)
            }
        })
    }

    @MainActor static func stopPreview() {
        generation = UUID()
        customSounds = []
        player.stop()
    }

    private static func loadCustomSounds() -> [NotificationSound] {
        guard let directory = try? directory() else { return [] }
        return (try? loadCustomSounds(in: directory)) ?? []
    }

    static func loadCustomSounds(in directory: URL) throws -> [NotificationSound] {
        let file = directory.appendingPathComponent("catalog.json")
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: file)
        let choices = try JSONDecoder().decode([NotificationSound].self, from: data)
        var seen: Set<String> = []
        return Array(choices.filter { filename(for: $0) != nil && seen.insert($0.id).inserted }.prefix(256))
    }

    static func remember(
        _ sound: NotificationSound, in directory: URL, previous: [NotificationSound]
    ) throws -> [NotificationSound] {
        let choices = Array(([sound] + previous.filter { $0.id != sound.id }).prefix(256))
        try JSONEncoder().encode(choices).write(
            to: directory.appendingPathComponent("catalog.json"), options: .atomic
        )
        return choices
    }

    static func directory() throws -> URL {
        try SystemLaunchServices.supportDirectory().appendingPathComponent(
            "NotificationSounds",
            isDirectory: true
        )
    }

    static func importFile(_ source: URL, directory: URL) throws -> NotificationSound {
        if FileManager.default.fileExists(atPath: directory.path),
           try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        let file = try AVAudioFile(forReading: source)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0, duration < 30, file.processingFormat.channelCount <= 2,
              file.processingFormat.sampleRate <= 192_000 else { throw ImportFailure.unsupported }
        let buffer = try Ringtone.decode(source)
        let sound = NotificationSound(
            id: UUID().uuidString,
            name: source.deletingPathExtension().lastPathComponent
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename(for: sound)!)
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: buffer.format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = try AVAudioFile(
                forWriting: destination, settings: settings,
                commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved
            )
            try output.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return sound
    }

    static func filename(for sound: NotificationSound) -> String? {
        guard let id = UUID(uuidString: sound.id) else { return nil }
        return prefix + id.uuidString + ".aiff"
    }

    static func source(for sound: NotificationSound) throws -> URL? {
        if sound == .kibble {
            return AppSound.newMessage.url
        }
        guard let filename = filename(for: sound) else { return nil }
        let source = try directory().appendingPathComponent(filename)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return source
    }

    static func systemSound(_ sound: NotificationSound) -> UNNotificationSound {
        if sound == .system {
            return .default
        }
        guard let filename = filename(for: sound), let source = try? source(for: sound),
              let library = try? MessageNotificationSound.libraryDirectory() else {
            return MessageNotificationSound.sound
        }
        do {
            try MessageNotificationSound.install(source: source, library: library, filename: filename)
            return UNNotificationSound(named: UNNotificationSoundName(filename))
        } catch {
            return MessageNotificationSound.sound
        }
    }

    enum ImportFailure: LocalizedError {
        case unsupported
        var errorDescription: String? {
            "Choose a mono or stereo audio file shorter than 30 seconds."
        }
    }
}
