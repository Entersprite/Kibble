import Foundation

/// Bounded stages for a login window and its local trace.
enum LoginPageLocation: String {
    case opening, blank, identifier, password, challenge, expired, accounts, chat, meet, other
    static let waitingForChatStatus = "Signing in… (waiting for Chat itself to load)"

    init(_ url: URL?) {
        guard let url else { self = .opening; return }
        let scheme = url.scheme?.lowercased()
        if scheme == "about", url.path() == "blank" {
            self = .blank
            return
        }
        guard scheme == "https" else { self = .other; return }
        switch url.host()?.lowercased() {
        case "chat.google.com": self = .chat
        case "meet.google.com": self = .meet
        case "accounts.google.com": self = Self.accountsStage(at: url.path())
        default: self = .other
        }
    }

    private static func accountsStage(at path: String) -> Self {
        switch path {
        case "/info/sessionexpired": .expired
        case "/v3/signin/identifier", "/signin/v2/identifier": .identifier
        case "/v3/signin/challenge/pwd", "/signin/v2/challenge/pwd": .password
        default:
            path.hasPrefix("/v3/signin/challenge/") || path.hasPrefix("/signin/v2/challenge/")
                ? .challenge : .accounts
        }
    }

    var signInStatus: String? {
        switch self {
        case .identifier: "Enter your email address in the Google form."
        case .password: "Enter your password in the Google form."
        case .challenge: "Complete the verification in the Google form."
        case .expired: "Google sign-in expired."
        case .accounts: Self.waitingForChatStatus
        case .blank: "The sign-in page is blank. Use Restart Sign-In to reload it."
        case .opening, .chat, .meet, .other: nil
        }
    }
}
