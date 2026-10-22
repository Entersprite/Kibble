import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

private actor CardActionTransport: HTTPTransport {
    private(set) var submitted: [SubmitFormActionRequest] = []
    var message: GChatBridgeCore.Message

    init() {
        var value = GChatBridgeCore.Message()
        value.id.messageID = "message"
        value.id.parentID.topicID.topicID = "thread"
        value.id.parentID.topicID.groupID.spaceID.spaceID = "space"
        value.creator.userID.id = "bot"
        value.createTime = 1_000_000
        var attachment = GChatBridgeCore.Attachment()
        attachment.appID.id = "bot"
        var widget = JAddOnsWidget()
        var button = JAddOnsWidget.Button()
        button.textButton.text.originalText = "Acknowledge"
        button.textButton.onClick.action.actionMethodName = "acknowledge"
        button.textButton.onClick.action.encryptedAction = "opaque"
        widget.buttons = [button]
        var section = JAddOnsCardItem.CardItemSection()
        section.widgets = [widget]
        attachment.cardAddOnData.sections = [section]
        value.attachments = [attachment]
        message = value
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body: Data
        if request.url.path.contains("/mole/world") {
            body = Data(LocalBridgeBackendTests.shell(app: "DynamiteWebUi").utf8)
        } else if request.url.path.contains("/api/list_messages") {
            var response = ListMessagesResponse()
            response.messages = [message]
            body = try response.serializedData()
        } else if request.url.path.contains("/api/submit_form_action") {
            try submitted.append(SubmitFormActionRequest(serializedBytes: request.body ?? Data()))
            var response = SubmitFormActionResponse()
            response.cardItem.header.title.originalText = "Received by app"
            body = try response.serializedData()
        } else {
            body = Data()
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw CancellationError()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CardActionTests {
    @Test func onlyAnActionStillPresentOnTheAddressedProviderMessageCanBeInvoked() async throws {
        let transport = CardActionTransport()
        let cookies = try #require(SessionCookies(header: "SID=a; COMPASS=b; OSID=c"))
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        try await backend.connect()
        let source = await transport.message
        let message = try #require(ChannelEventMapping.domainMessage(source))
        let action = try #require(message.cards.first?.actions?.first)
        var request = AppCardActionRequest(
            conversation: message.conversationID,
            thread: message.threadID,
            message: message.id,
            action: action
        )
        let result = try await backend.invokeCardAction(request)
        #expect(result.card?.header?.title.plainText == "Received by app")
        let calls = await transport.submitted
        #expect(calls.count == 1)
        let wire = try #require(calls.first)
        #expect(wire.messageID == source.id)
        #expect(wire.topicID == source.id.parentID.topicID)
        #expect(wire.botID.id == "bot")
        #expect(wire.action.encryptedAction == "opaque")
        #expect(wire.hasRequestHeader)
        #expect(wire.dialogEvent == 1)
        var forged = source.attachments[0]
        var forgedButton = forged.cardAddOnData.sections[0].widgets[0].buttons[0]
        forgedButton.textButton.onClick.action.encryptedAction = "forged"
        forged.cardAddOnData.sections[0].widgets[0].buttons[0] = forgedButton
        request
            .action = try #require(CardMapping.cards([forged]).first?.actions?.first)
        await #expect(throws: ChatError.self) { _ = try await backend.invokeCardAction(request) }
        #expect(await transport.submitted.count == 1)
        request.action = action
        request.message = ChatKit.Message.ID("foreign-message")
        await #expect(throws: ChatError.self) { _ = try await backend.invokeCardAction(request) }
        #expect(await transport.submitted.count == 1)
        await backend.disconnect()
    }
}
