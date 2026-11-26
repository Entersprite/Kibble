import ChatKit
import Foundation

extension ConversationBrowser {
    /// `ChatError` is not a `LocalizedError`, so its `localizedDescription`
    /// is Foundation's "(ChatKit.ChatError error 6.)"; a sheet says it in words.
    static func message(_ error: any Error) -> String {
        let fallback = "The operation could not be completed. Please reload and try again."
        guard let error = error as? ChatError else { return fallback }
        switch error {
        case .notAuthenticated, .sessionExpired: return "Signed out. Sign in again and try again."
        case .rateLimited: return "Too many requests right now. Try again in a moment."
        case .unsupported: return "This account can’t do that."
        case .signInRequired: return "Sign in again to do that."
        case .transport: return "The connection failed. Check your network and try again."
        case let .decoding(message), let .server(_, message), let .unknown(message):
            return message.isEmpty ? fallback : message
        }
    }
}
