import ChatAPI
import ChatKit
import Foundation

func serviceFailure(_ error: any Error) -> ServiceFailure {
    if let failure = error as? ServiceFailure {
        return failure
    }
    let safe: ChatError = switch error {
    case ChatError.notAuthenticated: .notAuthenticated
    case ChatError.sessionExpired: .sessionExpired
    case let ChatError.rateLimited(delay): .rateLimited(retryAfter: delay)
    case let ChatError.unsupported(capability): .unsupported(capability: capability)
    default: .unknown("The account operation could not be completed.")
    }
    return ServiceFailure(code: "providerFailure", details: try? ServiceCodec.value(safe))
}
