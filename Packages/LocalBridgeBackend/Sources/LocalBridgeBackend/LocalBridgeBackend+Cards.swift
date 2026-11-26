import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func invokeCardAction(_ action: AppCardActionRequest) async throws -> AppCardActionResult {
        guard capabilities.canInvokeCardActions
        else { throw ChatError.unsupported(capability: "cardActions") }
        guard let client = apiClient, let group = ChannelEventMapping.groupID(for: action.conversation),
              !action.message.rawValue.isEmpty, !action.thread.rawValue.isEmpty,
              action.action.id.utf8.count <= 65536 else { throw ChatError.decoding("Invalid app action") }
        let generation = directoryGeneration
        // Never trust a caller-created callback token, or act on a card that
        // the app has replaced or deleted since it was drawn.
        let messages = try await loadThread(action.thread, in: action.conversation)
        guard generation == directoryGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        guard let message = messages.first(where: { $0.id == action.message && !$0.isDeleted }),
              message.cards
              .contains(where: { $0.actions?.contains(where: { $0.id == action.action.id }) == true }),
              let bytes = Data(base64Encoded: action.action.id),
              let token = try? JSONDecoder().decode(CardInteractionMapping.Token.self, from: bytes)
        else { throw ChatError.decoding("This app action has changed. Open the conversation to refresh it.") }
        var request = SubmitFormActionRequest()
        request.dialogEvent = 1
        request.messageID.messageID = action.message.rawValue
        request.messageID.parentID.topicID.topicID = action.thread.rawValue
        request.messageID.parentID.topicID.groupID = group
        request.groupID = group
        request.topicID = request.messageID.parentID.topicID
        request.botID = try UserId(serializedBytes: token.bot)
        request.action = try JAddOnsFormAction(serializedBytes: token.action)
        request.requestHeader = APIRequestHeader.make()
        let response: SubmitFormActionResponse
        do {
            response = try await client.call(.submitFormAction, request)
        } catch { throw Self.chatError(fromAPI: error, call: "the app action request") }
        try Task.checkCancellation()
        guard generation == directoryGeneration else { throw CancellationError() }
        // Unknown bot/dialog/status responses must not masquerade as success.
        guard response.unknownFields.data.isEmpty else {
            throw ChatError
                .unknown(
                    "The app returned a response that needs the web client. "
                        + "Check its state there before trying again."
                )
        }
        return AppCardActionResult(
            card: response.hasCardItem ? CardMapping.card(response.cardItem) : nil,
            setupURL: CardMapping.target(response.setupURL)
        )
    }
}
