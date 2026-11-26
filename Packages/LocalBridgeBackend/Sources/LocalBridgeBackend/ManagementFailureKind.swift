import ChatKit
import GChatBridgeCore

/// A failure's kind without its payload, for `ProviderDiagnostic.peopleListFailed`:
/// an undecodable body's detail or a server message can carry provider text.
///
/// **Why a diagnostic:** the service reduces every provider failure to one
/// neutral `ChatError.unknown` before it reaches a client, which is right for
/// the client and leaves nobody able to say which request refused.
enum ManagementFailureKind {
    static func of(_ error: any Error) -> String {
        switch error {
        case let failure as APIFailure: of(failure)
        case let failure as ChatError: of(failure)
        case is CancellationError: "cancelled"
        default: String(describing: type(of: error))
        }
    }

    private static func of(_ failure: APIFailure) -> String {
        switch failure {
        case let .transport(reason): "transport(\(reason.map { String(describing: $0) } ?? "unclassified"))"
        case let .httpStatus(status): "http(\(status))"
        case .emptyBody: "emptyBody"
        case let .undecodable(encodings, _): "undecodable(\(encodings.map { String(describing: $0) }))"
        }
    }

    private static func of(_ failure: ChatError) -> String {
        switch failure {
        case .notAuthenticated: "notAuthenticated"
        case .sessionExpired: "sessionExpired"
        case .rateLimited: "rateLimited"
        case .unsupported: "unsupported"
        case .signInRequired: "signInRequired"
        case .transport: "chatTransport"
        case .decoding: "decoding"
        case let .server(status, _): "server(\(status))"
        case .unknown: "unknown"
        }
    }
}
