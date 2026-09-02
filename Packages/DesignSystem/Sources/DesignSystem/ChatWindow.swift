import ChatKit
import SwiftUI

/// The whole window: sidebar, transcript, composer.
///
/// Everything it draws arrives in `state`, and everything it wants arrives back
/// through `actions`. It has never heard of a database or a backend, which is
/// what makes the same view work against a fixture, a live bridge, or a server.
public struct ChatWindow: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    public init(state: ChatSceneState, actions: ChatSceneActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        NavigationSplitView {
            ConversationList(state: state, actions: actions)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                StatusStrip(state: state, actions: actions)
                if let conversation = state.selectedConversation {
                    MessageList(state: state)
                    TypingStrip(state: state)
                    Divider()
                    if state.capabilities.canSendMessages {
                        Composer(
                            placeholder: Display.title(
                                of: conversation,
                                directory: state.directory,
                                me: state.me
                            ),
                            send: actions.send
                        )
                        // The draft belongs to the conversation it was typed
                        // in. Without this the `if let` branch keeps its
                        // identity across a selection change, `@State draft`
                        // survives, and a half-typed line addressed to one
                        // person posts to whoever was opened next. Cheap to
                        // miss, expensive to send.
                        .id(conversation.id)
                    } else {
                        // Not a disabled field: a greyed-out composer invites
                        // the user to keep clicking it. Saying why is kinder.
                        Text("This backend cannot send messages yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                } else {
                    ContentUnavailableView(
                        "Pick a conversation",
                        systemImage: "sidebar.left",
                        description: Text("Choose one from the sidebar to read it.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
    }

    private var title: String {
        guard let conversation = state.selectedConversation else { return "GChat" }
        return Display.title(of: conversation, directory: state.directory, me: state.me)
    }

    private var subtitle: String {
        guard let conversation = state.selectedConversation else { return "" }
        let people = conversation.members.count
        return people == 1 ? "1 member" : "\(people) members"
    }
}

/// Connection and errors, read from the store like everything else - which is
/// why a view can show them without ever touching a backend.
struct StatusStrip: View {
    let state: ChatSceneState
    /// Required rather than defaulted: a defaulted `ChatSceneActions()` has no
    /// `signIn`, so a call site that forgot it would silently draw a banner
    /// with no way out - which is the bug this parameter exists to fix.
    let actions: ChatSceneActions

    var body: some View {
        // `banner` (a real problem) takes priority over `notice` (a clean
        // diagnostic run that merely finished) - nothing sets both at once
        // today, but a warning worth acting on must never be the one that
        // loses if that ever changes.
        if let message = banner {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                Spacer()
                // Drawn only where the host offered one. A window with no
                // route back to sign-in is a window a person can only escape
                // by editing their Keychain - see `ChatSceneActions.signIn`.
                if let signIn = actions.signIn {
                    Button("Sign in again", action: signIn)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.yellow.opacity(0.22))
        } else if let notice = state.notice {
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

    private var banner: String? {
        if let error = state.lastError {
            return description(of: error)
        }
        switch state.connection {
        case .connected: return nil
        case .idle: return "Not connected."
        case .connecting: return "Connecting…"
        case let .reconnecting(attempt): return "Reconnecting, attempt \(attempt)…"
        case let .disconnected(reason): return reason.map { "Disconnected: \($0)" } ?? "Disconnected."
        }
    }

    /// Rendered here rather than stored as a string, because the store keeps
    /// the error typed so a client can tell "sign in again" from a hiccup.
    private func description(of error: ChatError) -> String {
        switch error {
        case .notAuthenticated, .sessionExpired: "Signed out. Sign in again to keep syncing."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Rate limited. Retrying in \($0)." } ?? "Rate limited."
        case let .unsupported(capability): "This backend cannot \(capability)."
        case let .transport(message): "Connection problem: \(message)"
        case let .decoding(message): "Could not read a message: \(message)"
        case let .server(status, message): "Server error \(status): \(message)"
        case let .unknown(message): message
        }
    }
}

struct TypingStrip: View {
    let state: ChatSceneState

    var body: some View {
        if !state.typing.isEmpty {
            let names = state.typing.map { Display.name(of: $0, in: state.directory) }
            Text(names.count == 1 ? "\(names[0]) is typing…" : "\(names.count) people are typing…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }
}
