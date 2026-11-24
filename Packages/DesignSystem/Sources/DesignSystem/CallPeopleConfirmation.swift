import ChatKit
import SwiftUI

/// What the People list asks before a change that reaches other people:
/// the question, what it means for them, and the button that does it.
struct CallPeopleConfirmation {
    let title: String
    let message: String
    let button: String
    var role: ButtonRole?
    let activity: CallActivity

    static let muteAll = CallPeopleConfirmation(
        title: "Mute everyone else?", message: "Participants can unmute themselves.",
        button: "Mute All", activity: CallActivity("muteAllParticipants")
    )

    static let lowerAllHands = CallPeopleConfirmation(
        title: "Lower all raised hands?", message: "This clears the meeting’s raised hands.",
        button: "Lower All", activity: CallActivity("lowerAllHands")
    )

    static func remove(_ entry: CallRosterEntry) -> CallPeopleConfirmation {
        CallPeopleConfirmation(
            title: "Remove \(entry.name)?", message: "They’ll be disconnected from this call.",
            button: "Remove", role: .destructive,
            activity: CallActivity("removeParticipant", resourceID: entry.id)
        )
    }

    static func sendToWaitingRoom(_ entry: CallRosterEntry) -> CallPeopleConfirmation {
        CallPeopleConfirmation(
            title: "Send \(entry.name) to the waiting room?",
            message: "They’ll leave the call until a host brings them back.",
            button: "Send to Waiting Room", role: .destructive,
            activity: CallActivity("sendParticipantToWaitingRoom", resourceID: entry.id)
        )
    }

    static func block(_ entry: CallRosterEntry) -> CallPeopleConfirmation {
        CallPeopleConfirmation(
            title: "Block \(entry.name) from this meeting?",
            message: "They’ll be removed and will need a new invitation to rejoin.",
            button: "Block", role: .destructive,
            activity: CallActivity("blockParticipant", resourceID: entry.id)
        )
    }

    static func denyAdmissions(_ ids: [UUID]) -> CallPeopleConfirmation {
        var activity = CallActivity("respondToAdmissions", enabled: false)
        activity.participantIDs = ids
        return CallPeopleConfirmation(
            title: "Deny all join requests?", message: "This applies to the people asking to join now.",
            button: "Deny All", role: .destructive, activity: activity
        )
    }

    static func clearSharedPin(_ id: UUID, name: String) -> CallPeopleConfirmation {
        CallPeopleConfirmation(
            title: "Unpin \(name) for everyone?",
            message: "Participants can still pin this tile for themselves.",
            button: "Unpin", activity: CallActivity("setPinForEveryone", resourceID: id, enabled: false)
        )
    }
}
