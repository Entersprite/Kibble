import Foundation
import GChatBridgeCore

public extension MeetDMCallTrial {
    /// Only errors this package understands get descriptions. Underlying
    /// transport errors may carry keys or URLs and are never interpolated.
    nonisolated static func errorDescription(_ error: any Error) -> String {
        if let error = error as? MeetDMCallTrialError {
            return trialError(error)
        }
        if let error = error as? APIFailure {
            return error.safeDescription
        }
        if let error = error as? MeetCallClientError {
            return callError(error)
        }
        if let error = error as? MeetCallBootstrapError {
            return shellError(error)
        }
        if let error = error as? MeetPushBootstrapError {
            return pushBootstrapError(error)
        }
        if let error = error as? CallMediaError {
            return mediaError(error)
        }
        if let error = error as? MeetDeviceSessionError {
            return deviceError(error)
        }
        if error is CancellationError {
            return "Operation cancelled."
        }
        if let error = error as? MeetAudioOffer.AnswerFailure {
            return "Meet media answer was invalid at " + error.rawValue + "."
        }
        return otherError(error)
    }

    private nonisolated static func otherError(_ error: any Error) -> String {
        if error is MeetCallWire.WireError {
            return "Meet response or request shape was invalid."
        }
        if error is BootstrapFailure {
            return "Chat bootstrap failed."
        }
        return "Request failed."
    }

    private nonisolated static func trialError(_ error: MeetDMCallTrialError) -> String {
        switch error {
        case .noSession: "No Chat session is stored."
        case .signedOut: "The Chat session is signed out."
        case .missingSelf: "Chat did not return the current account's identity."
        case .accountChanged: "The Chat sign-in changed. Reload the people list."
        case .invalidPerson: "Choose a person from the current DM list."
        case .callNotPrepared: "Prepare a new call before ringing again."
        case .superseded: "The call preparation was replaced or closed."
        case .browserJoinRequired: "Join the call in your browser, then confirm the join before ringing."
        case .callChanged: "The DM's call changed. Prepare a new call and join it again."
        case .missingPushConfiguration:
            "Neither Chat page supplied supported Meet watch configuration. Copy Report."
        }
    }

    private nonisolated static func callError(_ error: MeetCallClientError) -> String {
        switch error {
        case let .httpStatus(status, refusal): "HTTP \(status); \(refusal.safeDescription)"
        case .missingSessionProof: "No scoped Google session proof; request was not sent."
        case .missingMeetingToken: "Resolve did not return a meeting token."
        case .inviteRejected: "The invitation response lacked an acknowledgement."
        }
    }

    private nonisolated static func shellError(_ error: MeetCallBootstrapError) -> String {
        switch error {
        case let .httpStatus(status): "Meet shell returned HTTP \(status)."
        case let .redirected(status, _): "Meet shell redirected (HTTP \(status))."
        case .missingClientKey: "Meet shell did not contain a unique client key."
        case .invalidRTCClientMetadata: "Meet shell did not contain valid RTC client metadata."
        }
    }

    private nonisolated static func pushBootstrapError(_ error: MeetPushBootstrapError) -> String {
        switch error {
        case let .httpStatus(status): "Standalone Chat page returned HTTP \(status)."
        case let .redirected(status):
            "Standalone Chat page redirected (HTTP \(status)); watch bootstrap stopped."
        case .invalidShell: "Standalone Chat page has no readable shell configuration."
        case .signedOut: "Standalone Chat page did not confirm a signed-in Chat session."
        }
    }

    private nonisolated static func mediaError(_ error: CallMediaError) -> String {
        switch error {
        case .microphoneDenied: "Microphone access was denied."
        case .busy: "Native audio is already preparing a call."
        case .closed: "Native audio was closed."
        case .negotiationFailed: "Native audio negotiation failed."
        case .connectionFailed: "Native audio transport failed."
        case .timedOut: "Native audio did not connect within 20 seconds."
        }
    }

    private nonisolated static func deviceError(_ error: MeetDeviceSessionError) -> String {
        switch error {
        case .busy: "The native device has an operation in progress."
        case .closed: "The native call was closed."
        case .deviceExists: "A device registration was already attempted. Prepare a new call."
        case .noDevice: "Meet has no registered native caller device."
        case .mediaNotConnected: "Native audio is not connected."
        case .notJoined: "Meet has not confirmed the native caller as joined."
        case .leaveUnconfirmed: "Meet did not confirm that the caller device left."
        }
    }
}
