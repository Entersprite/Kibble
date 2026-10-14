import Foundation
import GChatBridgeCore

extension LocalBridgeAudioCallService {
    /// Fixed call-stage descriptions only. Provider messages, URLs and opaque
    /// identifiers must never enter ordinary window state.
    static func failureMessage(_ error: any Error) -> String {
        if let error = error as? MeetCallBootstrapError {
            return bootstrapFailureMessage(error)
        }
        if let error = error as? MeetCallClientError {
            return clientFailureMessage(error)
        }
        if let error = error as? CallMediaError {
            return mediaFailureMessage(error)
        }
        return "The call could not connect."
    }

    private static func bootstrapFailureMessage(_ error: MeetCallBootstrapError) -> String {
        switch error {
        case .redirected(_, .accounts):
            "Call sign-in is required. The calling service redirected to sign-in."
        case .redirected:
            "Call setup failed: the calling service redirected unexpectedly."
        case let .httpStatus(status):
            "Call setup was refused (HTTP \(status))."
        case .missingClientKey, .invalidRTCClientMetadata:
            "Call setup failed: calling configuration is unavailable."
        }
    }

    private static func clientFailureMessage(_ error: MeetCallClientError) -> String {
        switch error {
        case .httpStatus(401, _), .httpStatus(403, _), .missingSessionProof:
            "Calling credentials were rejected. Call sign-in is required."
        case let .httpStatus(status, _):
            "Call setup was refused (HTTP \(status))."
        default: "Call setup could not be acknowledged."
        }
    }

    private static func mediaFailureMessage(_ error: CallMediaError) -> String {
        switch error {
        case .microphoneDenied: "Microphone access is required to answer or place a call."
        case .outgoingAudioUnconfirmed: "Call audio registration could not be confirmed."
        case .negotiationFailed: "Call audio negotiation failed."
        case .timedOut, .connectionFailed: "Call audio could not connect."
        default: "Call audio setup failed."
        }
    }
}
