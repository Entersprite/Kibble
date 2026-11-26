import ChatKit

public extension FakeBackend {
    func invokeCardAction(_ action: AppCardActionRequest) async throws -> AppCardActionResult {
        guard capabilities.canInvokeCardActions
        else { throw ChatError.unsupported(capability: "cardActions") }
        guard let message = world.messages
            .first(where: { $0.id == action.message && $0.conversationID == action.conversation }),
            !message.isDeleted, message.threadID == action.thread,
            message.cards.contains(where: { $0.actions?.contains(action.action) == true }) else {
            throw ChatError.decoding("This app action is no longer available.")
        }
        return AppCardActionResult(card: AppCard(sections: [
            AppCard.Section(widgets: [.text(RichText("The app received your action."))])
        ]))
    }
}
