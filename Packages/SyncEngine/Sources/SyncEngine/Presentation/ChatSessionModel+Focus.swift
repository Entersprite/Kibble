import ChatKit
import ChatPersistence
import Foundation

public extension ChatSessionModel {
    /// Told by the app shell whether the app is frontmost.
    ///
    /// Becoming frontmost marks the open conversation, and the thread the
    /// panel shows, because otherwise everything that arrived while the user
    /// was away stays unread until a *new* message happens to arrive and
    /// trigger it.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if !active {
            stopTyping()
        }
        if active {
            // Another client can mark a message unread, post a new root, or
            // delete one while this window is away. The channel does not
            // guarantee replay of those changes, so foregrounding refreshes
            // the server's read state and the visible transcript together.
            if case .connected = connectionState {
                if foregroundRefreshTask == nil {
                    let visible = selected
                    foregroundRefreshTask = Task { [weak self, engine] in
                        defer {
                            if !Task.isCancelled {
                                self?.foregroundRefreshTask = nil
                            }
                        }
                        await engine.refreshVisibleConversation(visible)
                        // A selection may change while the shared world load
                        // waits. Reconcile the newest selection too so a
                        // second focus return cannot leave it stale.
                        var refreshed = visible
                        while !Task.isCancelled, let next = self?.selected, next != refreshed {
                            refreshed = next
                            await engine.refreshVisibleConversation(next)
                        }
                        guard !Task.isCancelled, self?.selected != nil else { return }
                        // Unchanged pages publish no observation. A completed
                        // foreground reconciliation is still a fresh trigger
                        // for a previously refused automatic read.
                        self?.markSelectedReadIfNeeded()
                        self?.markOpenThreadReadIfNeeded()
                    }
                }
            }
            markSelectedReadIfNeeded()
            markOpenThreadReadIfNeeded()
        }
    }
}
