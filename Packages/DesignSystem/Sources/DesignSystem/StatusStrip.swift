import ChatKit
import SwiftUI

/// Connection and errors, read from the store like everything else - which is
/// why a view can show them without ever touching a backend.
///
/// Drawn as the search results bar is, a glass capsule under the toolbar, so
/// the two bars read as one family. A problem carries the system's caution
/// symbol in its own colors and its recovery buttons; starting up is neutral
/// progress, never a warning (the owner's rule: connecting is progress).
struct StatusStrip: View {
    let state: ChatSceneState
    /// Required rather than defaulted: a defaulted `ChatSceneActions()` has no
    /// `signIn`, so a call site that forgot it would silently draw a banner
    /// with no way out - which is the bug this parameter exists to fix.
    let actions: ChatSceneActions
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        let headline = Self.headline(for: state)
        // A stack that is always there, so the announcement below has a view
        // to hang from while the strip shows nothing.
        VStack(spacing: 0) {
            // `headline(for:)` decides: an error, then a finished probe's
            // notice, then the connection. Ordinary startup is progress; a
            // real error always keeps its warning and recovery controls.
            switch headline {
            case let .warning(message)?:
                warning(message)
            case let .progress(message)?:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(message)
                }
                .foregroundStyle(.secondary)
                .contentBar()
            case let .notice(notice)?:
                // Neither the caution symbol nor its colors: this is what
                // closes the finding that a clean `--probe=keychain` run drew
                // exactly like a failure. A different symbol is the whole
                // fix - the words already said "written to a file", not "wrong".
                Label(notice, systemImage: "checkmark.circle.fill")
                    .contentBar()
            case nil:
                EmptyView()
            }
        }
        .font(.callout)
        .onChange(of: headline, initial: true) { _, headline in
            // Posted only while VoiceOver is on; nothing is posted otherwise.
            guard voiceOver, let spoken = Self.announcement(for: headline) else { return }
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    /// The words and the buttons on one line where they fit; in a narrow
    /// column, the buttons go under the words, which wrap rather than
    /// truncate.
    private func warning(_ message: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                warningText(message)
                recovery
            }
            VStack(alignment: .leading, spacing: 6) {
                warningText(message)
                HStack(spacing: 8) { recovery }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .contentBar()
    }

    private func warningText(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityLabel("Warning")
            VStack(alignment: .leading, spacing: 1) {
                Text(message)
                // Secondary, never the headline - diagnostic only (spec §8).
                // Drawn only when there is one, so the bar's height is
                // unchanged whenever there is nothing to add.
                if let detail = bannerDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var recovery: some View {
        // Drawn only where the host offered one, and only once
        // `ConnectionBanner.offersReconnect` says the wait has earned it -
        // see `ChatSceneActions.reconnect`.
        if canReconnect, let reconnect = actions.reconnect {
            Button("Reconnect Now", action: reconnect)
                .fixedSize()
        }
        // Drawn only where the host offered one. A window with no route back
        // to sign-in is a window a person can only escape by editing their
        // Keychain - see `ChatSceneActions.signIn`.
        if state.resourceSyncWarning == nil || state.lastError != nil, let signIn = actions.signIn {
            Button("Sign In Again", action: signIn)
                .fixedSize()
        }
    }

    enum Headline: Equatable {
        case warning(String)
        case notice(String)
        case progress(String)
    }

    /// What VoiceOver hears when the strip changes: a problem, as it appears.
    /// Progress is not news, and a probe's notice is for the person who ran it.
    static func announcement(for headline: Headline?) -> String? {
        guard case let .warning(message)? = headline else { return nil }
        return message
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
        switch state.connection {
        case .connected:
            return state.resourceSyncWarning.map(Headline.warning)
        case .idle:
            return nil
        case .connecting, .unknown:
            return .progress("Connecting…")
        case .reconnecting, .disconnected:
            break
        }
        return ConnectionBanner.text(
            for: state.connection, service: state.connectionService
        ).map(Headline.warning)
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

extension View {
    /// The content column's bars under the toolbar, the connection's and the
    /// search's, in one shape: glass around its content, centered, kept clear
    /// of the column's edges. A control layer over the window's background,
    /// never over a message.
    ///
    /// A capsule on one line (the corner is more than half a line's height, so
    /// the ends are round), and a rounded rectangle when a narrow column wraps
    /// the words, where a capsule's ends would cut into them.
    func contentBar() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: ContentBarLayout.cornerRadius, style: .continuous))
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
    }
}

enum ContentBarLayout {
    /// Half the height of a one-line bar with small buttons (36 pt, measured
    /// hosted), so every one-line bar is a capsule; a line of words alone is
    /// shorter, and its corner is clamped to the same round end.
    static let cornerRadius: CGFloat = 18
}
