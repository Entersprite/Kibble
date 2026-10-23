import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The webhook editor's draft: when Create or Save is offered, and what it sends.
struct WebhookEditorTests {
    @Test func newWebhookNeedsAName() {
        var draft = WebhookDraft(nil)
        #expect(draft.name.isEmpty)
        #expect(draft.avatarURL.isEmpty)
        #expect(!draft.isValid)
        draft.name = "   "
        #expect(!draft.isValid, "A name of spaces is no name.")
        draft.name = "CI Alerts"
        #expect(draft.isValid)
        #expect(draft.mutation == .saveWebhook(id: nil, name: "CI Alerts", avatarURL: ""))
        #expect(draft.mutation.action == "createWebhook")
    }

    @Test func avatarMustBeHTTPSWhenGiven() {
        var draft = WebhookDraft(nil)
        draft.name = "CI Alerts"
        draft.avatarURL = "http://x"
        #expect(!draft.isValid)
        draft.avatarURL = ""
        #expect(draft.isValid)
        draft.avatarURL = "https://x/y.png"
        #expect(draft.isValid)
        draft.avatarURL = "not a url"
        #expect(!draft.isValid)
        draft.avatarURL = "https://"
        #expect(!draft.isValid, "An address needs a host.")
    }

    @Test func editingKeepsTheWebhookID() {
        let webhook = ConversationWebhook(
            id: "w1", name: "Deploys", avatarURL: URL(string: "https://example.test/hook.png"),
            allowedActions: ["editWebhook", "deleteWebhook"]
        )
        var draft = WebhookDraft(webhook)
        #expect(draft.name == "Deploys")
        #expect(draft.avatarURL == "https://example.test/hook.png")
        #expect(draft.isValid)
        draft.name = " Deploy Alerts "
        #expect(draft.mutation == .saveWebhook(
            id: "w1", name: "Deploy Alerts", avatarURL: "https://example.test/hook.png"
        ))
        #expect(draft.mutation.action == "editWebhook")
    }
}
