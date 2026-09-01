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
                StatusStrip(state: state)
                if let conversation = state.selectedConversation {
                    MessageList(state: state)
                    TypingStrip(state: state)
                    Divider()
                    Composer(
                        placeholder: Display.title(
                            of: conversation,
                            directory: state.directory,
                            me: state.me
                        ),
                        send: actions.send
                    )
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

    var body: some View {
        if let message = banner {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.yellow.opacity(0.22))
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
