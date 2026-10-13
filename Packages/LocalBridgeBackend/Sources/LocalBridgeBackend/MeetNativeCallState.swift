import Foundation

public enum MeetNativeCallEndReason: String, Sendable {
    case localEnded, ringCancelled, remoteEnded, declined, invitationEnded, ringingTimedOut, transportFailed,
         accountChanged, deviceEnded, joinFailed
}

/// Native trial state reflects observed media and provider collections. An
/// acknowledged invitation alone never means that the peer answered.
public enum MeetNativeCallState: Sendable, Equatable {
    case ready, ringing, active, reconnecting, stateUnavailable, ending
    case ended(MeetNativeCallEndReason)

    public var message: String {
        switch self {
        case .ready: "Native audio joined. Ready to ring the selected person."
        case .ringing: "Invitation sent. Waiting for the other person to join…"
        case .active: "Call active. Another joined device is present."
        case .reconnecting: "Audio connection interrupted. Waiting for it to recover…"
        case .stateUnavailable: "Call status is unavailable. You can still end the call."
        case .ending: "Ending the native call…"
        case .ended(.joinFailed): "Native call could not connect."
        case .ended(.localEnded): "Native call ended."
        case .ended(.ringCancelled): "Ringing cancelled. Check the report for confirmation."
        case .ended(.deviceEnded): "Meet ended Kibble's device. Native call ended."
        case .ended(.remoteEnded): "The other device left. Native call ended."
        case .ended(.declined): "The call was declined."
        case .ended(.invitationEnded): "The invitation ended before another device joined."
        case .ended(.ringingTimedOut): "No joined device was observed before the ringing timeout."
        case .ended(.transportFailed): "Native audio connection failed. Call ended."
        case .ended(.accountChanged): "The call session changed. Call ended."
        }
    }
}
