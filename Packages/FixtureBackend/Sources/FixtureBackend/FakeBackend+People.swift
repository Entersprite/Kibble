import ChatKit
import Foundation

/// The directory and membership, for `--backend=fixture` (mention
/// non-members spec §3.6).
public extension FakeBackend {
    /// A prefix of any word of the name, or of the email, ignoring case:
    /// enough to drive the `@` list's directory section.
    func searchPeople(_ query: String) async throws -> [Member] {
        try requireConnected()
        let needle = query.lowercased()
        return directory.filter { person in
            let words = (person.displayName ?? "").lowercased().split(separator: " ").map(String.init)
            return words.contains { $0.hasPrefix(needle) } || (person.email ?? "").lowercased()
                .hasPrefix(needle)
        }
    }

    func membership(
        of member: Member.ID,
        in conversation: Conversation.ID
    ) async throws -> ConversationMembership {
        try requireConnected()
        guard let found = world.conversation(conversation) else { return .unknown }
        return found.members.contains(member) ? .member : .notMember
    }
}
