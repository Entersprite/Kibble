import ChatAPI
import ChatKit
import Foundation

struct CallOperationFailure {
    let id: UUID
    let code: String
    var providerCategory: String?
    var stage: String?

    init(id: UUID, error: any Error) {
        self.id = id
        if let failure = error as? ServiceFailure, failure.code == "invalidRequest",
           case let .object(details) = failure.details,
           case let .string(stage) = details["callStage"],
           ["meetingLinkEnvelope", "meetingLinkNormalization"].contains(stage) {
            code = "invalidRequest"
            self.stage = stage
            return
        }
        if let failure = error as? ServiceFailure, failure.code == "providerFailure" {
            code = "providerFailure"
            if case let .object(details) = failure.details,
               case let .string(type) = details["type"],
               ["notAuthenticated", "sessionExpired", "rateLimited", "unsupported", "unknown"]
               .contains(type) {
                providerCategory = type
            }
            return
        }
        // Unknown wire codes/details and underlying error descriptions can carry
        // arbitrary text. Only fixed, locally known categories enter this report.
        let known: [ServiceFailure] = [
            .notAuthorized, .invalidRequest, .deviceBusy, .staleCallSource, .staleAccount,
            .authenticationRequired, .accountDisabled, .accountNotFound, .accountCleanupPending,
            .overloaded, .deadlineExceeded, .unsupportedOperation, .invalidResponse, .internalFailure,
            .operationConflict, .operationExpired, .ownerBusy, .duplicateRequest
        ]
        code = known.first(where: { $0 == error as? ServiceFailure })?.code ?? "unclassified"
    }
}

public extension AudioCallController {
    /// Redacted client control context, available even if provider setup never began.
    /// A previous call/account's failure must not be exported for its replacement.
    func diagnosticReport(callID: UUID) -> String? {
        guard let call, call.id == callID, isAvailable else { return nil }
        var lines = [
            "Call diagnostic format: 2",
            "Call client: active",
            "Call terminal: \(call.phase.isTerminal)"
        ]
        switch call.target {
        case .person:
            lines.append("Call target: person")
        case let .conversation(target):
            if let url = target.meetingURL {
                lines.append("Call target: meetingLink")
                lines += MeetingLinkDiagnosticShape.lines(url, supportedHosts: supportedMeetingLinkHosts)
            } else {
                lines.append("Call target: conversation")
            }
        }
        lines
            .append("Call intent: " +
                (call.isJoining ? "join" : call.direction == .incoming ? "incoming" : "start"))
        if let operationFailure, operationFailure.id == callID {
            lines.append("Call control failure: \(operationFailure.code)")
            if let stage = operationFailure.stage {
                lines.append("Call failure stage: " + stage)
            }
            if let category = operationFailure.providerCategory {
                lines.append("Call provider failure category: " + category)
            }
        }
        return lines.joined(separator: "\n")
    }
}
