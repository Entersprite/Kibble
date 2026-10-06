import Foundation

/// Whether someone is in a conversation, as a backend can tell on request
/// (mention non-members spec §3.1). `.unknown` is "could not tell", which the
/// composer treats as not a member, so it asks rather than guesses.
public enum ConversationMembership: Hashable, Sendable {
    case member
    case notMember
    case unknown
}
