import Foundation

/// Public code URLs and the native /meet/code route normalize to the same code.
/// All query parameters are discarded
/// before resolution; they cannot select an account, endpoint or joining mode.
public struct MeetJoinLink: Equatable, Sendable {
    public let code: String
    public let url: URL

    public init(_ input: URL) throws {
        guard input.absoluteString.utf8.count <= 2048,
              let components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "meet.google.com",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.fragment == nil else { throw MeetCallWire.WireError.invalidIdentifier }
        var path = components.percentEncodedPath
        if path.hasPrefix("/meet/") {
            path.removeFirst(5)
        }
        if path.hasSuffix("/") {
            path.removeLast()
        }
        guard path.utf8.count == 13, path.first == "/" else { throw MeetCallWire.WireError.invalidIdentifier }
        let code = String(path.dropFirst())
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [3, 4, 3],
              parts.allSatisfy({ $0.utf8.allSatisfy { (97 ... 122).contains($0) } })
        else { throw MeetCallWire.WireError.invalidIdentifier }
        self.code = code
        url = URL(string: "https://meet.google.com/" + code)!
    }
}
