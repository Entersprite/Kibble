import ChatAPI
import Foundation

struct CallOperationFailure {
    let id: UUID
    let code: String

    init(id: UUID, error: any Error) {
        self.id = id
        // Unknown wire codes/details and underlying error descriptions can carry
        // arbitrary text. Only fixed, locally known categories enter this report.
        let known: [ServiceFailure] = [
            .notAuthorized, .invalidRequest, .deviceBusy, .staleCallSource, .staleAccount,
            .authenticationRequired, .accountDisabled, .accountNotFound, .accountCleanupPending,
            .overloaded, .deadlineExceeded, .unsupportedOperation, .invalidResponse, .internalFailure
        ]
        code = known.first(where: { $0 == error as? ServiceFailure })?.code ?? "unclassified"
    }
}

public extension AudioCallController {
    /// Redacted client control context, available even if provider setup never began.
    /// A previous call/account's failure must not be exported for its replacement.
    func diagnosticReport(callID: UUID) -> String? {
        guard let call, call.id == callID, isAvailable else { return nil }
        var lines = ["Call client: active", "Call terminal: \(call.phase.isTerminal)"]
        if let operationFailure, operationFailure.id == callID {
            lines.append("Call control failure: \(operationFailure.code)")
        }
        return lines.joined(separator: "\n")
    }
}
