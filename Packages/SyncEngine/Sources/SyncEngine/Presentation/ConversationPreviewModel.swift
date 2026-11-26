import ChatKit
import Observation

/// Ephemeral preview ownership, separate from joined transcript state.
@MainActor @Observable
final class ConversationPreviewModel {
    private(set) var preview: ConversationPreview?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    func load(in id: Conversation.ID, using engine: SyncEngine, isCurrent: @escaping @MainActor () -> Bool) {
        clear()
        guard engine.capabilities.canPreviewConversations else { return }
        isLoading = true
        task = Task { [weak self] in
            do {
                let value = try await engine.loadConversationPreview(id)
                guard let self, !Task.isCancelled, isCurrent() else { return }
                preview = value
                isLoading = false
            } catch {
                guard let self, !Task.isCancelled, isCurrent() else { return }
                self.error = ConversationBrowser.message(error)
                isLoading = false
            }
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        preview = nil
        isLoading = false
        error = nil
    }
}
