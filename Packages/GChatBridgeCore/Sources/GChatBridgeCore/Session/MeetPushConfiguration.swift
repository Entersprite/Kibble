import Foundation

/// Account-specific Meet watch configuration from the Chat shell. The project
/// and topic are opaque provider values; descriptions expose only lengths.
public struct MeetPushConfiguration: Sendable, Hashable, CustomStringConvertible {
    public let key: String
    public let project: String
    public let topic: String

    public init?(key: String, project: String, topic: String) {
        guard Self.token(key, maximum: 256), Self.token(project, maximum: 256),
              Self.validTopic(topic) else { return nil }
        self.key = key
        self.project = project
        self.topic = topic
    }

    public var description: String {
        "MeetPushConfiguration(key: \(key.utf8.count) bytes, project: \(project.utf8.count) bytes, "
            + "topic: \(topic.utf8.count) bytes)"
    }

    static func read(_ fields: [String: Any]) -> MeetPushConfiguration? {
        // The web client defaults TyXQle to production (1). A dev/unknown
        // environment must not silently route its opaque topic to production.
        guard environment(fields["TyXQle"]) == "production",
              let key = fields["wU9aJb"] as? String,
              let project = fields["pZ68sc"] as? String,
              let topic = fields["ttqQxf"] as? String else { return nil }
        return MeetPushConfiguration(key: key, project: project, topic: topic)
    }

    static func diagnostics(_ fields: [String: Any]) -> [String] {
        let values = ["wU9aJb", "pZ68sc", "ttqQxf"].map { key in
            let shape: String = if let text = fields[key] as? String {
                "string, \(text.utf8.count) bytes, " + (validField(key, text) ? "valid" : "invalid")
            } else {
                fields[key] == nil ? "absent" : "not a string"
            }
            return "Meet watch config \(key): \(shape)"
        }
        return values + ["Meet watch environment: " + environment(fields["TyXQle"])]
    }

    private static func environment(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "production" }
        let number: Double? = if let text = value as? String {
            Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let value = value as? NSNumber, String(cString: value.objCType) != "c" {
            value.doubleValue
        } else {
            nil
        }
        switch number {
        case 1: return "production"
        case 2: return "development"
        case .none: return "malformed"
        default: return "unsupported"
        }
    }

    private static func validField(_ key: String, _ value: String) -> Bool {
        key == "ttqQxf" ? validTopic(value) : token(value, maximum: 256)
    }

    /// The web client copies this opaque string into one JSON/protobuf path
    /// part. It is not an HTTP header or URL segment. Preserve all UTF-8 bytes;
    /// the JSON encoder escapes control characters without altering the value.
    private static func validTopic(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048
    }

    private static func token(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy { (33 ... 126).contains($0) }
    }
}
