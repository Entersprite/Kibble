import Foundation

/// Opaque client operation identity with an immutable birth time. A service can
/// refuse expired retries after compacting its deduplication journal.
public enum ClientOperationID {
    public static func make(at instant: Date = Date()) -> String {
        let milliseconds = Int64(instant.timeIntervalSince1970 * 1000)
        return "op1:\(milliseconds):\(UUID().uuidString)"
    }

    public static func createdAt(_ value: String) -> Date? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "op1",
              let milliseconds = Int64(parts[1]), milliseconds >= 0,
              String(milliseconds) == parts[1],
              let id = UUID(uuidString: String(parts[2])), id.uuidString == parts[2] else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
