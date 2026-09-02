import ChatKit
import Foundation

/// What things are called on screen.
///
/// Every function here has a fallback that is never blank. A missing name
/// renders as an empty row that looks like a rendering bug, and the one case
/// guaranteed to hit it is a Chat app: the API returns only a name and a type
/// for one, and there is no profile anywhere to look up.
public enum Display {
    /// A conversation's title, derived when the server did not send one.
    ///
    /// `nil` and `""` are different: an empty string is a title the server
    /// really sent, and deriving over it would be overriding it.
    public static func title(
        of conversation: Conversation,
        directory: [Member.ID: Member],
        me: Member.ID?
    ) -> String {
        if let title = conversation.title {
            return title
        }
        let others = conversation.members.filter { $0 != me }
        guard !others.isEmpty else { return conversation.id.rawValue }
        return others.map { name(of: $0, in: directory) }.joined(separator: ", ")
    }

    /// A person's name, or their identifier if nobody has told us one.
    public static func name(of member: Member.ID, in directory: [Member.ID: Member]) -> String {
        guard let name = directory[member]?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else {
            return member.rawValue
        }
        return name
    }

    /// Who the sidebar footer says is signed in, including the moment before
    /// `me` has resolved at all.
    ///
    /// A resolved id with no directory entry yet still falls through to
    /// `name(of:in:)`'s own fallback - the raw identifier - the same partial
    /// answer `ConversationRow` and `TypingStrip` already show for anyone
    /// else not yet in the directory, so a signed-in person is not a special
    /// case. Only `me == nil` gets a different answer: there is no
    /// identifier at all to fall back to yet, and a footer visible the
    /// instant a session starts still needs to draw something during that
    /// gap. "Signed in" says a session exists without asserting an identity
    /// this client does not have - the same choice as leaving a control out
    /// entirely rather than drawing it half-empty.
    public static func signedInLabel(me: Member.ID?, directory: [Member.ID: Member]) -> String {
        guard let me else { return "Signed in" }
        return name(of: me, in: directory)
    }

    /// Up to two letters for an avatar circle.
    public static func initials(of member: Member.ID, in directory: [Member.ID: Member]) -> String {
        let resolved = name(of: member, in: directory)
        let words = resolved.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
        let letters = words.prefix(2).compactMap(\.first)
        guard !letters.isEmpty else { return "?" }
        if letters.count == 1 {
            return String(resolved.prefix(2)).uppercased()
        }
        return String(letters).uppercased()
    }
}
