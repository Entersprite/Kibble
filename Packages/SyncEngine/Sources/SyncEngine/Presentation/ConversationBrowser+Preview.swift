import ChatKit

extension ConversationBrowser {
    /// The open panel's recent messages, for a conversation not joined. Kept
    /// here only while its panel is open; never stored.
    public var preview: ConversationPreview? {
        previewState.preview
    }

    public var isLoadingPreview: Bool {
        previewState.isLoading
    }

    public var previewError: String? {
        previewState.error
    }

    var previewTask: Task<Void, Never>? {
        previewState.task
    }

    func loadPreview(_ id: Conversation.ID) {
        let current = generation
        previewState.load(in: id, using: engine) { [weak self] in
            self?.stopped == false && self?.generation == current && self?.panelTarget == id
        }
    }

    func forgetPreview() {
        previewState.clear()
    }
}
