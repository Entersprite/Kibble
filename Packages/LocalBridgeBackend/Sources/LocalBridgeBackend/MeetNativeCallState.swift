import ChatKit
import Foundation

public enum MeetNativeCallEndReason: String, Sendable {
    case localEnded, ringCancelled, remoteEnded, declined, invitationEnded, ringingTimedOut, transportFailed,
         accountChanged, deviceEnded, joinFailed, removedFromMeeting, sentToWaitingRoom, switchedDevice,
         conferenceEnded, incompatibleClient

    static let compatibilityNotice =
        "The current meeting settings require a compatible app. Open the meeting in your browser."

    func endNotice(cleanup: MeetNativeCallCleanup) -> String? {
        guard self == .incompatibleClient else { return cleanup.message }
        return cleanup.message.map { Self.compatibilityNotice + " " + $0 } ?? Self.compatibilityNotice
    }
}

/// Native trial state reflects observed media and provider collections. An
/// acknowledged invitation alone never means that the peer answered.
public enum MeetNativeCallState: Sendable, Equatable {
    case ready, ringing, active, reconnecting, stateUnavailable, ending
    case awaitingAdmission(CallAdmission)
    case ended(MeetNativeCallEndReason)
    case endedUnconfirmed(MeetNativeCallEndReason, MeetNativeCallCleanup)

    public var isTerminal: Bool {
        switch self {
        case .ended, .endedUnconfirmed: true
        default: false
        }
    }

    public var message: String {
        switch self {
        case .ready: "Native audio joined. Ready to ring the selected person."
        case .ringing: "Invitation sent. Waiting for the other person to join…"
        case .active: "Call active. Another joined device is present."
        case .awaitingAdmission(.waitingRoom): "Waiting in the meeting’s waiting room."
        case .awaitingAdmission: "Waiting for the meeting host to respond."
        case .reconnecting: "Audio connection interrupted. Waiting for it to recover…"
        case .stateUnavailable: "Call status is unavailable. You can still end the call."
        case .ending: "Ending the native call…"
        case let .endedUnconfirmed(_, cleanup): cleanup.message ?? "Native call ended."
        case .ended(.joinFailed): "Native call could not connect."
        case .ended(.localEnded): "Native call ended."
        case .ended(.ringCancelled): "Ringing cancelled. Check the report for confirmation."
        case .ended(.deviceEnded): "Meet ended Kibble's device. Native call ended."
        case .ended(.incompatibleClient): "Meet rejected this client for compatibility. Native call ended."
        case .ended(.removedFromMeeting): "Removed from the meeting."
        case .ended(.sentToWaitingRoom): "Sent to the waiting room."
        case .ended(.switchedDevice): "Call switched to another device."
        case .ended(.conferenceEnded): "Meeting ended."
        case .ended(.remoteEnded): "The other device left. Native call ended."
        case .ended(.declined): "The call was declined."
        case .ended(.invitationEnded): "The invitation ended before another device joined."
        case .ended(.ringingTimedOut): "No joined device was observed before the ringing timeout."
        case .ended(.transportFailed): "Native audio connection failed. Call ended."
        case .ended(.accountChanged): "The call session changed. Call ended."
        }
    }
}
