import Darwin
import Foundation
import UserNotifications

/// macOS Notification Center resolves custom names from the user sound library.
/// Keep a uniquely named, app-owned cue there; the app remains sandboxed.
enum MessageNotificationSound {
    static let name = "Kibble-Message-1"
    static let filename = name + ".aiff"

    static var sound: UNNotificationSound {
        UNNotificationSound(named: UNNotificationSoundName(filename))
    }

    static func install() throws {
        let library = try libraryDirectory()
        guard let source = AppSound.newMessage.url else { throw CocoaError(.fileNoSuchFile) }
        try install(source: source, library: library)
    }

    /// Both URLs are host-owned; tests supply an isolated Library directory.
    static func install(source: URL, library: URL) throws {
        let sounds = library.appendingPathComponent("Sounds", isDirectory: true)
        let destination = sounds.appendingPathComponent(filename)
        let data = try Data(contentsOf: source)
        guard (try? Data(contentsOf: destination)) != data else { return }
        try prepareDirectory(sounds)
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    static func libraryDirectory() throws -> URL {
        // Foundation redirects the current user's home into the app container.
        // The native sound server searches the actual user's Library/Sounds.
        var storage = [CChar](repeating: 0, count: max(16384, Int(sysconf(_SC_GETPW_R_SIZE_MAX))))
        let path = storage.withUnsafeMutableBufferPointer { buffer -> String? in
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(getuid(), &record, buffer.baseAddress, buffer.count, &result) == 0,
                  let directory = result?.pointee.pw_dir else { return nil }
            return String(cString: directory)
        }
        guard let path else {
            throw CocoaError(.fileNoSuchFile)
        }
        let home = URL(fileURLWithPath: path, isDirectory: true)
        return home.appendingPathComponent("Library", isDirectory: true)
    }

    private static func prepareDirectory(_ sounds: URL) throws {
        // Do not write through a user-customized sound-library link.
        let path = sounds.path(percentEncoded: false).replacingOccurrences(
            of: "/$",
            with: "",
            options: .regularExpression
        )
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
