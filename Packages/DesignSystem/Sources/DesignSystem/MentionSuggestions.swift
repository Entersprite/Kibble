import ChatKit
import Foundation

/// One row of the `@` list.
public struct MentionSuggestion: Hashable, Sendable, Identifiable {
    public let target: Mention.Target
    /// What a pick inserts after the `@`.
    public let name: String
    /// `nil` for `@all`.
    public let member: Member?

    public var id: String {
        switch target {
        case let .user(id): "user/\(id.rawValue)"
        case .all: "all"
        case let .unknown(type, _): "unknown/\(type)"
        }
    }
}

/// The `@` list's matching (mention composer spec §2), pure so each rule is a
/// test, the shape `EmojiPickerModel` follows. Candidates arrive ranked
/// (`ChatStore.fetchMentionCandidates`), and the order is kept.
enum MentionSuggestions {
    static let limit = 8

    static func suggestions(
        for query: String,
        candidates: [Member],
        includeAll: Bool
    ) -> [MentionSuggestion] {
        let needle = fold(query)
        var results: [MentionSuggestion] = []
        if includeAll, "all".hasPrefix(needle) {
            results.append(MentionSuggestion(target: .all, name: "all", member: nil))
        }
        for member in candidates where results.count < limit {
            guard let name = member.displayName, !name.isEmpty else { continue }
            guard needle.isEmpty || matches(needle, name: name, email: member.email) else { continue }
            results.append(MentionSuggestion(target: .user(member.id), name: name, member: member))
        }
        return results
    }

    /// A prefix of the whole name, of any word in it, or of the email's local part.
    static func matches(_ needle: String, name: String, email: String?) -> Bool {
        let folded = fold(name)
        if folded.hasPrefix(needle) {
            return true
        }
        var index = folded.startIndex
        while let space = folded[index...].firstIndex(where: \.isWhitespace) {
            index = folded.index(after: space)
            if folded[index...].hasPrefix(needle) {
                return true
            }
        }
        if let local = email?.split(separator: "@").first, fold(String(local)).hasPrefix(needle) {
            return true
        }
        return false
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
