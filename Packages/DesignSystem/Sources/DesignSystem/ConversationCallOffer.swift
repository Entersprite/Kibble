import ChatKit
import Foundation

/// What a conversation's header offers for calls, decided by the client from
/// its own call and a fresh discovery answer. A transcript's call entries
/// never decide it: they are history, and an old one says nothing about now.
public enum ConversationCallOffer: Equatable, Sendable {
    /// Start a call: a DM rings the person, a group or space starts quietly.
    case call
    /// A call was just observed going on here and this session is not in it.
    /// `participants` is the count the answer gave, when it gave one.
    case join(participants: Int?)
    /// This session's own call is in this conversation.
    case returnToCall

    /// Return to Call, then a fresh Join, then Call: the session's own call
    /// always wins, and an unknown or stale answer only ever offers Call.
    public static func resolve(
        inCall: Bool, observedActive: Bool, canJoin: Bool, canCall: Bool, participants: Int?
    ) -> Self? {
        if inCall {
            return .returnToCall
        }
        if observedActive, canJoin {
            return .join(participants: participants)
        }
        return canCall ? .call : nil
    }

    /// The help tag and VoiceOver hint for Join.
    static func joinHelp(participants: Int?) -> String {
        switch participants {
        case nil, 0?: "Join the call going on in this conversation"
        case 1?: "Join the call; 1 person is in it"
        case let count?: "Join the call; \(count) people are in it"
        }
    }
}
