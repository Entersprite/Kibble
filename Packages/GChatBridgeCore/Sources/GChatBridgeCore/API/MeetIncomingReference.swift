import Foundation

/// Equality against an already validated resolved DM. A bare space ID names
/// the same resource as its `spaces/` form; unrelated calls never match.
public enum MeetIncomingReference {
    public enum Match: String, Sendable {
        case code = "meeting code"
        case compactCode = "unhyphenated meeting code"
        case spaceName = "space resource name"
        case spaceID = "bare space ID"
        case url = "exact Meet URL"
        case resolvedAlias = "server-resolved reference"
        case none = "no matching reference"
    }

    public static func match(_ identifier: String, space: MeetCallWire.Space) -> Match {
        guard !identifier.isEmpty else { return .none }
        if identifier == space.code {
            return .code
        }
        if isCompactMatch(identifier, formatted: space.code) {
            return .compactCode
        }
        if identifier == space.name {
            return .spaceName
        }
        if identifier == space.url.absoluteString {
            return .url
        }
        if space.name.hasPrefix("spaces/"),
           identifier == String(space.name.dropFirst("spaces/".count)),
           !identifier.contains("/") {
            return .spaceID
        }
        return .none
    }

    private static func isCompactMatch(_ identifier: String, formatted: String) -> Bool {
        let parts = formatted.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.utf8.count) == [3, 4, 3],
              parts.allSatisfy({ $0.utf8.allSatisfy { (97 ... 122).contains($0) } }) else { return false }
        return identifier == parts.joined()
    }

    public static func diagnostic(_ identifier: String, call: MeetResolvedCall) -> String {
        let direct = match(identifier, space: call.space)
        let result = call.resolvesIncomingReference(identifier)
            ? (direct == .none ? Match.resolvedAlias : direct) : .none
        return diagnostic(identifier, match: result)
    }

    public static func diagnostic(_ identifier: String, space: MeetCallWire.Space) -> String {
        diagnostic(identifier, match: match(identifier, space: space))
    }

    private static func diagnostic(_ identifier: String, match result: Match) -> String {
        let shape = if identifier.hasPrefix("spaces/") {
            "space resource"
        } else if URL(string: identifier)?.scheme != nil {
            "URL"
        } else {
            "bare identifier"
        }
        return "Incoming call reference: \(identifier.utf8.count) bytes; \(shape); "
            + result.rawValue
    }
}
