import Foundation

/// A sound selection, not a filesystem path. Custom assets are owned by the
/// delivering host; a missing asset falls back to Kibble's bundled cue.
public struct NotificationSound: Codable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let kibble = NotificationSound(id: "kibble", name: "Kibble")
    public static let system = NotificationSound(id: "system", name: "System Default")
}
