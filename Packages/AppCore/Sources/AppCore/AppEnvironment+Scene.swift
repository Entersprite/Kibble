import ChatKit
import DesignSystem
import Foundation
import SyncEngine

/// The launch machine, as a window sees it.
///
/// Separate from the state machine because they are two jobs, and because
/// `swiftlint --strict` enforces `type_body_length: 300` - the combined type
/// was close enough to the limit that the split is not merely tidiness.
public extension AppEnvironment {
    /// For the menu-bar agent, which has no room for a sidebar.
    var totalUnread: Int {
        guard case let .running(model) = phase else { return 0 }
        return model.conversations.reduce(0) { $0 + $1.unreadCount }
    }

    var sceneState: ChatSceneState {
        guard case let .running(model) = phase else {
            // `.failed` and `.report` are not the same kind of non-running:
            // one is a real problem and the other is a clean diagnostic run
            // that merely finished, and the two must not render under the
            // same warning triangle - see `StatusStrip` in `ChatWindow.swift`.
            // `lastError` and `notice` are how that distinction survives past
            // this point; collapsing them back into one string is exactly the
            // bug that put a triangle over a passing keychain check.
            switch phase {
            case let .failed(message):
                return ChatSceneState(lastError: .unknown(message))
            case let .report(message):
                return ChatSceneState(notice: message)
            case .loading, .needsSignIn, .running:
                return ChatSceneState()
            }
        }
        return ChatSceneState(
            conversations: model.conversations,
            directory: model.directory,
            me: model.me,
            selected: model.selected,
            messages: model.messages,
            typing: model.typing,
            connection: model.connectionState,
            lastError: model.lastError,
            capabilities: model.capabilities
        )
    }

    var actions: ChatSceneActions {
        ChatSceneActions(
            select: { [weak self] id in
                guard case let .running(model) = self?.phase else { return }
                model.select(id)
            },
            send: { [weak self] text in
                guard case let .running(model) = self?.phase else { return }
                model.send(text)
            },
            // Offered **only** from `.failed`, which is the phase that had no
            // way out. `.needsSignIn` already shows the capture window,
            // `.running` must not invite someone to re-authenticate a working
            // session over one transient banner, and a probe report is not a
            // session problem at all.
            signIn: isFailed ? { [weak self] in self?.requestSignIn() } : nil
        )
    }

    private var isFailed: Bool {
        if case .failed = phase {
            return true
        }
        return false
    }
}
