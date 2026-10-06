import ChatKit
import SwiftUI

/// Who the `@` list offers, or `nil` for no list: the backend cannot mention
/// (`Capabilities.canMention`), or the platform has no text view for tokens.
public struct ComposerMentions {
    public var candidates: [Member]
    public var includeAll: Bool
    /// Directory people for the active query, shown after the members
    /// (mention non-members spec §2).
    public var directory: [Member]
    /// Told the active `@` query, or `nil` when there is none.
    public var queryChanged: ((String?) -> Void)?
    /// Told when a directory person is picked, so their membership is checked.
    public var outsidePicked: ((Member.ID) -> Void)?
    /// Who in a message is not in the conversation. `nil` never asks.
    public var nonMembers: (@MainActor (ComposedMessage) async -> [Member.ID])?
    /// Sends into this composer's own conversation, after the check; `nil`
    /// uses the composer's plain `send` (review finding 2).
    public var sendHere: ((ComposedMessage) -> Void)?
    /// Hands an unsent message back to this conversation's draft, when the
    /// composer goes away mid-check or with the confirmation open.
    public var keepHere: ((ComposedMessage) -> Void)?

    public init(
        candidates: [Member],
        includeAll: Bool,
        directory: [Member] = [],
        queryChanged: ((String?) -> Void)? = nil,
        outsidePicked: ((Member.ID) -> Void)? = nil,
        nonMembers: (@MainActor (ComposedMessage) async -> [Member.ID])? = nil,
        sendHere: ((ComposedMessage) -> Void)? = nil,
        keepHere: ((ComposedMessage) -> Void)? = nil
    ) {
        self.candidates = candidates
        self.includeAll = includeAll
        self.directory = directory
        self.queryChanged = queryChanged
        self.outsidePicked = outsidePicked
        self.nonMembers = nonMembers
        self.sendHere = sendHere
        self.keepHere = keepHere
    }
}
