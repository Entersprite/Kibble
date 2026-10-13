import Foundation

/// Meet timestamps token rotations; concurrent older responses must not
/// replace a newer device token. Tokens remain credentials, never diagnostics.
struct MeetMeetingToken: Sendable {
    private(set) var value: String?
    private var timestamp: UInt64 = 0

    mutating func absorb(_ token: String?) {
        guard let token, token.utf8.count <= 16384,
              let separator = token.firstIndex(of: ";"),
              let next = UInt64(token[..<separator]),
              separator < token.index(before: token.endIndex),
              !token.contains("\r"), !token.contains("\n"),
              value == nil || next > timestamp else { return }
        timestamp = next
        value = token
    }
}
