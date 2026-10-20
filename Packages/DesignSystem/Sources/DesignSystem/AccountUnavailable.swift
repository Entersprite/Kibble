import SwiftUI

/// Why the selected account shows no conversations, and what fixes it. Drawn
/// by `ChatWindow` in place of its empty state, so the sidebar, the toolbar and
/// the account pill stay exactly where they are while an account is not running.
public struct AccountUnavailable {
    public enum Reason: Equatable, Sendable {
        case connecting
        case disabled
        case signInRequired
        case failed(String)
        case removing
    }

    public let label: String
    public let reason: Reason
    public var enable: (() -> Void)?
    /// Signs in again after `.signInRequired`, retries after `.failed` or a
    /// connection that does not come up.
    public var reconnect: (() -> Void)?
    public var copyDiagnostics: (() -> Void)?

    public init(
        label: String, reason: Reason, enable: (() -> Void)? = nil, reconnect: (() -> Void)? = nil,
        copyDiagnostics: (() -> Void)? = nil
    ) {
        self.label = label
        self.reason = reason
        self.enable = enable
        self.reconnect = reconnect
        self.copyDiagnostics = copyDiagnostics
    }
}

struct AccountUnavailableView: View {
    let unavailable: AccountUnavailable

    var body: some View {
        switch unavailable.reason {
        case .connecting:
            ContentUnavailableView {
                ProgressView().controlSize(.large)
            } description: {
                Text("Connecting \(unavailable.label)…")
            } actions: {
                if let reconnect = unavailable.reconnect {
                    Button("Try Again", action: reconnect)
                }
            }
        case .disabled:
            ContentUnavailableView {
                Label("\(unavailable.label) Is Disabled", systemImage: "pause.circle")
            } description: {
                Text("It keeps its conversations on this Mac, but does not connect or notify you.")
            } actions: {
                if let enable = unavailable.enable {
                    Button("Enable Account", action: enable).buttonStyle(.glassProminent)
                }
            }
        case .signInRequired:
            ContentUnavailableView {
                Label("Sign In Again", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("\(unavailable.label) was signed out. Sign in to connect it again.")
            } actions: {
                if let reconnect = unavailable.reconnect {
                    Button("Reconnect…", action: reconnect).buttonStyle(.glassProminent)
                }
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("\(unavailable.label) Could Not Connect", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let reconnect = unavailable.reconnect {
                    Button("Try Again", action: reconnect).buttonStyle(.glassProminent)
                }
                if let copy = unavailable.copyDiagnostics {
                    Button("Copy Diagnostics", action: copy)
                }
            }
        case .removing:
            ContentUnavailableView {
                ProgressView().controlSize(.large)
            } description: {
                Text("Removing \(unavailable.label) from this Mac…")
            }
        }
    }
}

/// The whole window before any account can be shown: starting up, a start-up
/// failure, or no account yet.
public struct AccountsPlaceholder: View {
    public enum Phase: Equatable, Sendable {
        case starting
        case failed(String)
        case noAccounts
    }

    let phase: Phase
    let retry: (() -> Void)?
    let addAccount: (() -> Void)?

    public init(phase: Phase, retry: (() -> Void)? = nil, addAccount: (() -> Void)? = nil) {
        self.phase = phase
        self.retry = retry
        self.addAccount = addAccount
    }

    public var body: some View {
        Group {
            switch phase {
            case .starting:
                ProgressView("Starting accounts…")
            case let .failed(message):
                ContentUnavailableView {
                    Label("Accounts Could Not Start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    if let retry {
                        Button("Try Again", action: retry).buttonStyle(.glassProminent)
                    }
                }
            case .noAccounts:
                ContentUnavailableView {
                    Label("Welcome to Kibble", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Add an account to see its conversations here.")
                } actions: {
                    if let addAccount {
                        Button("Add Account…", action: addAccount).buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
