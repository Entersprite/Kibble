import ChatAPI
import ChatKit
import Foundation

func serviceFailure(_ error: any Error, forDownload: Bool = false) -> ServiceFailure {
    if let failure = error as? ServiceFailure {
        return failure
    }
    let safe: ChatError = switch error {
    case ChatError.notAuthenticated: .notAuthenticated
    case ChatError.sessionExpired: .sessionExpired
    case let ChatError.rateLimited(delay): .rateLimited(retryAfter: delay)
    case let ChatError.unsupported(capability): .unsupported(capability: capability)
    case ChatError.transport
        where forDownload: .transport("The download connection was interrupted. Try again.")
    default: .unknown("The account operation could not be completed.")
    }
    return ServiceFailure(code: "providerFailure", details: try? ServiceCodec.value(safe))
}
