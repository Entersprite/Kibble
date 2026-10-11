import ChatKit
import SwiftUI

/// Connection and errors, read from the store like everything else - which is
/// why a view can show them without ever touching a backend.
struct StatusStrip: View {
    let state: ChatSceneState
    /// Required rather than defaulted: a defaulted `ChatSceneActions()` has no
    /// `signIn`, so a call site that forgot it would silently draw a banner
    /// with no way out - which is the bug this parameter exists to fix.
    let actions: ChatSceneActions

    var body: some View {
        // `headline(for:)` decides: an error, then a finished probe's
        // notice, then the connection. A warning worth acting on never loses
        // to a notice; "Not connected." always does.
        if case let .warning(message) = Self.headline(for: state) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                    Spacer()
                    // Drawn only where the host offered one, and only once
                    // `ConnectionBanner.offersReconnect` says the wait has
                    // earned it - see `ChatSceneActions.reconnect`.
                    if canReconnect, let reconnect = actions.reconnect {
                        Button("Reconnect now", action: reconnect)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    // Drawn only where the host offered one. A window with no
                    // route back to sign-in is a window a person can only
                    // escape by editing their Keychain - see
                    // `ChatSceneActions.signIn`.
                    if let signIn = actions.signIn {
                        Button("Sign in again", action: signIn)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                // Secondary, never the headline - diagnostic only (spec §8).
                // Drawn only when there is one, so the banner's height is
                // unchanged whenever there is nothing to add.
                if let detail = bannerDetail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.yellow.opacity(0.22))
        } else if case let .notice(notice) = Self.headline(for: state) {
            // Neither the triangle nor the yellow wash: this is what closes
            // the finding that a clean `--probe=keychain` run drew exactly
            // like a failure. A different icon and background are the whole
            // fix - the words already said "written to a file", not "wrong".
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text(notice)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.12))
        }
    }

    enum Headline: Equatable {
        case warning(String)
        case notice(String)
    }

    /// One line, by precedence:
    /// 1. A real error: `lastError` is what a client can act on.
    /// 2. A notice: a finished `--probe=` run's result. It outranks the
    ///    connection, because a probe scene is never connected, and `.idle`'s
    ///    "Not connected." used to hide every probe's result (session 51).
    /// 3. The connection banner.
    static func headline(for state: ChatSceneState) -> Headline? {
        if let error = state.lastError {
            return .warning(description(of: error))
        }
        if let notice = state.notice {
            return .notice(notice)
        }
        return ConnectionBanner.text(for: state.connection).map(Headline.warning)
    }

    /// Same precedence as `banner`: a real error's own description already
    /// carries everything relevant (a status code, a capability name), so
    /// there is no separate diagnostic line to add underneath it.
    private var bannerDetail: String? {
        guard state.lastError == nil, state.notice == nil else { return nil }
        return ConnectionBanner.detail(for: state.connection)
    }

    private var canReconnect: Bool {
        ConnectionBanner.offersReconnect(for: state.connection)
    }

    /// Rendered here rather than stored as a string, because the store keeps
    /// the error typed so a client can tell "sign in again" from a hiccup.
    private static func description(of error: ChatError) -> String {
        switch error {
        case .notAuthenticated, .sessionExpired: "Signed out. Sign in again to keep syncing."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Rate limited. Retrying in \($0)." } ?? "Rate limited."
        case let .unsupported(capability): "This backend cannot \(capability)."
        case .signInRequired: "Sign in again to download files."
        case let .transport(message): "Connection problem: \(message)"
        case let .decoding(message): "Could not read a message: \(message)"
        case let .server(status, message): "Server error \(status): \(message)"
        case let .unknown(message): message
        }
    }
}
