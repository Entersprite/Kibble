import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct CardInteractionMappingTests {
    private func attachment(_ name: String) -> GChatBridgeCore.Attachment {
        var value = GChatBridgeCore.Attachment()
        value.appID.id = "bot"
        value.cardAddOnData.header.title.originalText = name
        var widget = JAddOnsWidget()
        var button = JAddOnsWidget.Button()
        button.textButton.text.originalText = "Acknowledge"
        button.textButton.onClick.action.actionMethodName = "acknowledge"
        button.textButton.onClick.action.encryptedAction = "opaque-action"
        var parameter = JAddOnsFormAction.ActionParameter()
        parameter.key = "issue"
        parameter.value = "example"
        button.textButton.onClick.action.parameters = [parameter]
        widget.buttons = [button]
        var section = JAddOnsCardItem.CardItemSection()
        section.widgets = [widget]
        value.cardAddOnData.sections = [section]
        return value
    }

    @Test(arguments: ["Linear", "GitHub", "Google Drive", "Sentry"])
    func formFreeCallbacksKeepTheCompleteProviderIssuedAction(_ app: String) throws {
        let source = attachment(app)
        var group = GroupId()
        group.spaceID.spaceID = "example"
        let mapped = try #require(CardMapping.cards([source], group: group).first)
        let action = try #require(mapped.actions?.first)
        #expect(action.label == "Acknowledge")
        let data = try #require(Data(base64Encoded: action.id))
        let token = try JSONDecoder().decode(CardInteractionMapping.Token.self, from: data)
        #expect(try UserId(serializedBytes: token.bot) == source.appID)
        let decoded = try JAddOnsFormAction(serializedBytes: token.action)
        #expect(decoded == source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.onClick.action)
        #expect(mapped.interactionFallback?.url.absoluteString == "https://chat.google.com/room/example")
    }

    @Test func formsDialogsAndDisabledButtonsNeverSendAnIncompleteNativeAction() throws {
        var source = attachment("Example app")
        var group = GroupId()
        group.dmID.dmID = "example"
        source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.disabled = true
        #expect(CardMapping.cards([source], group: group).first?.actions == nil)
        source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.disabled = false
        source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.onClick.action.interaction = 1
        let dialog = try #require(CardMapping.cards([source], group: group).first)
        #expect(dialog.actions == nil)
        #expect(dialog.interactionFallback?.url.absoluteString == "https://chat.google.com/dm/example")
        source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.onClick.action.interaction = 0
        var input = JAddOnsWidget()
        input.textField.name = "summary"
        source.cardAddOnData.sections[0].widgets.append(input)
        let form = try #require(CardMapping.cards([source], group: group).first)
        #expect(form.actions == nil)
        #expect(form.interactionFallback != nil)
        #expect(!form.isEmpty)
    }
}
