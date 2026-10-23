import ChatKit
import SwiftUI

/// Who in a message is outside its conversation, and how "Add and Send" can
/// add them (mention non-members spec §2).
public struct ComposerOutsiders: Equatable, Sendable {
    public enum Adding: Equatable, Sendable {
        /// The message adds them: their mentions are sent as `.invite`.
        case byMention
        /// The host adds them first, then sends (`ComposerMentions.addAndSend`).
        case beforeSending
        /// They cannot be added from here.
        case unavailable
    }

    public var people: [Member.ID]
    public var adding: Adding

    public init(people: [Member.ID] = [], adding: Adding = .byMention) {
        self.people = people
        self.adding = adding
    }
}

/// Who the `@` list offers, or `nil` for no list: the backend cannot mention
/// (`Capabilities.canMention`), or the platform has no text view for tokens.
public struct ComposerMentions {
    public var candidates: [Member]
    public var includeAll: Bool
    /// Directory people for the active query, shown after the members
    /// (mention non-members spec §2).
    public var directory: [Member]
    /// The query `directory` answers. A different query shows none of them:
    /// another composer's `@` may be what was searched. `nil` answers any.
    public var directoryQuery: String?
    /// What the conversation is called where someone is not in it: "Not in
    /// this space", "isn't in this group chat".
    public var place: String
    /// Told the active `@` query, or `nil` when there is none.
    public var queryChanged: ((String?) -> Void)?
    /// Told when a directory person is picked, so their membership is checked.
    public var outsidePicked: ((Member.ID) -> Void)?
    /// Who in a message is not in the conversation. `nil` never asks.
    public var nonMembers: (@MainActor (ComposedMessage) async -> ComposerOutsiders)?
    /// Adds the people, then sends into this composer's own conversation or
    /// thread; `nil` offers no "Add and Send" where the message cannot add them.
    public var addAndSend: ((ComposedMessage, [Member.ID]) -> Void)?
    /// Sends into this composer's own conversation, after the check; `nil`
    /// uses the composer's plain `send`.
    public var sendHere: ((ComposedMessage) -> Void)?
    /// Hands an unsent message back to this conversation's draft, when the
    /// composer goes away mid-check or with the confirmation open.
    public var keepHere: ((ComposedMessage) -> Void)?

    public init(
        candidates: [Member],
        includeAll: Bool,
        directory: [Member] = [],
        directoryQuery: String? = nil,
        place: String = "space",
        queryChanged: ((String?) -> Void)? = nil,
        outsidePicked: ((Member.ID) -> Void)? = nil,
        nonMembers: (@MainActor (ComposedMessage) async -> ComposerOutsiders)? = nil,
        addAndSend: ((ComposedMessage, [Member.ID]) -> Void)? = nil,
        sendHere: ((ComposedMessage) -> Void)? = nil,
        keepHere: ((ComposedMessage) -> Void)? = nil
    ) {
        self.candidates = candidates
        self.includeAll = includeAll
        self.directory = directory
        self.directoryQuery = directoryQuery
        self.place = place
        self.queryChanged = queryChanged
        self.outsidePicked = outsidePicked
        self.nonMembers = nonMembers
        self.addAndSend = addAndSend
        self.sendHere = sendHere
        self.keepHere = keepHere
    }

    /// The directory people to list for `query`: none when they answer
    /// another one.
    func directory(for query: String) -> [Member] {
        directoryQuery == nil || directoryQuery == query ? directory : []
    }

    /// The noun the `@` list and the confirmation use for a conversation of
    /// `kind`, where someone may not be in it.
    public static func place(of kind: Conversation.Kind) -> String {
        kind == .groupDirectMessage ? "group chat" : "space"
    }
}
