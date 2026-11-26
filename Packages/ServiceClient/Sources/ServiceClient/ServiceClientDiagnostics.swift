import ChatAPI
import ChatKit
import Foundation

/// Content-free observations. The host supplies logging; transport payloads stay private.
public enum ServiceClientDiagnostic: Sendable {
    case pinReadFinished(count: Int)
    case pinReadFailed(stage: String, failure: String)
    case mediaReadFailed(failure: String)
}

public struct ServiceClientDiagnostics: Sendable {
    public let record: @Sendable (ServiceClientDiagnostic) -> Void

    public init(record: @escaping @Sendable (ServiceClientDiagnostic) -> Void = { _ in }) {
        self.record = record
    }
}

extension ServiceBackend {
    static func pinFailureKind(_ error: any Error) -> String {
        if let failure = error as? ServiceFailure {
            let allowed: Set = [
                "overloaded",
                "deadlineExceeded",
                "notAuthorized",
                "invalidRequest",
                "invalidResponse",
                "frameTooLarge",
                "cancelled",
                "resynchronizationRequired",
                "providerFailure",
                "accountDisabled",
                "accountCleanupPending",
                "internalFailure"
            ]
            return allowed.contains(failure.code) ? failure.code : "otherServiceFailure"
        }
        if error is CancellationError {
            return "cancelled"
        }
        switch error as? ChatError {
        case .notAuthenticated?: return "notAuthenticated"
        case .sessionExpired?: return "sessionExpired"
        case .unknown?: return "providerUnknown"
        default: return "other"
        }
    }
}
