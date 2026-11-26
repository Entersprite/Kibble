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

    /// No card links to the web client: what this client cannot do is left
    /// out, never handed to Google Chat in a browser.
    private func expectNoWebClientLink(_ card: AppCard, sourceLocation: SourceLocation = #_sourceLocation) {
        let urls = card.sections.flatMap(\.widgets).flatMap { widget -> [URL] in
            switch widget {
            case let .buttons(buttons): buttons.map(\.url)
            case let .decorated(row): row.button.map { [$0.url] } ?? []
            default: []
            }
        }
        #expect(!urls.contains { $0.host() == "chat.google.com" }, "\(urls)", sourceLocation: sourceLocation)
    }

    @Test(arguments: ["Linear", "GitHub", "Google Drive", "Sentry"])
    func formFreeCallbacksKeepTheCompleteProviderIssuedAction(_ app: String) throws {
        let source = attachment(app)
        let mapped = try #require(CardMapping.cards([source]).first)
        let action = try #require(mapped.actions?.first)
        #expect(action.label == "Acknowledge")
        let data = try #require(Data(base64Encoded: action.id))
        let token = try JSONDecoder().decode(CardInteractionMapping.Token.self, from: data)
        #expect(try UserId(serializedBytes: token.bot) == source.appID)
        let decoded = try JAddOnsFormAction(serializedBytes: token.action)
        #expect(decoded == source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.onClick.action)
        expectNoWebClientLink(mapped)
    }

    @Test func formsDialogsAndDisabledButtonsNeverSendAnIncompleteNativeAction() throws {
        var source = attachment("Example app")
        source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.disabled = true
        #expect(CardMapping.cards([source]).first?.actions == nil)
        source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.disabled = false
        source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.onClick.action.interaction = 1
        let dialog = try #require(CardMapping.cards([source]).first)
        #expect(dialog.actions == nil)
        expectNoWebClientLink(dialog)
        source.cardAddOnData.sections[0].widgets[0].buttons[0].textButton.onClick.action.interaction = 0
        var input = JAddOnsWidget()
        input.textField.name = "summary"
        source.cardAddOnData.sections[0].widgets.append(input)
        let form = try #require(CardMapping.cards([source]).first)
        #expect(form.actions == nil)
        expectNoWebClientLink(form)
        // Its header still shows; only the form is left out.
        #expect(!form.isEmpty)
    }
}
