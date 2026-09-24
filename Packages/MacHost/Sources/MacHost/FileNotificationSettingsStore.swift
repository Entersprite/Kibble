import AppCore
import ChatKit
import Foundation

/// One JSON file per account, `notification-settings/<account>.json`, beside
/// the database in the sandbox container (spec §3). Pretty-printed with sorted
/// keys so a person can read it, and written atomically.
public struct FileNotificationSettingsStore: NotificationSettingsStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var settingsDirectory: URL {
        directory.appendingPathComponent("notification-settings", isDirectory: true)
    }

    /// Percent-encoded down to alphanumerics, so `/` cannot make a path and two
    /// ids that differ only by an escape cannot collide (Review Focus 2).
    static func fileName(for account: Member.ID) -> String {
        let safe = account.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? account
            .rawValue
        return "\(safe).json"
    }

    public func load(for account: Member.ID) throws -> NotificationSettings? {
        let url = settingsDirectory.appendingPathComponent(Self.fileName(for: account))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(NotificationSettings.self, from: data)
        } catch {
            // Moved aside, not left for the next save to overwrite: whatever
            // is in it may still be worth recovering by hand. The timestamp
            // stays for a person reading the directory; the UUID suffix is
            // what makes the name collision-proof, because two unreadable
            // loads can land in the same second. With the UUID, the only way
            // this `try?` still fails is a filesystem error in this same
            // directory - and that would fail the next `save` too, so there
            // is nothing more useful to do here than leave the corrupt file
            // where it is and report the read failure, which the `throw`
            // below already does.
            let stamp = Int(Date().timeIntervalSince1970)
            let unique = UUID().uuidString.prefix(8)
            let aside = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(stamp)-\(unique).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            throw error
        }
    }

    public func save(_ settings: NotificationSettings, for account: Member.ID) throws {
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings)
            .write(
                to: settingsDirectory.appendingPathComponent(Self.fileName(for: account)),
                options: .atomic
            )
    }

    /// Created once per install and never synced.
    public func deviceID() throws -> String {
        let url = directory.appendingPathComponent("device-id")
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }
}
