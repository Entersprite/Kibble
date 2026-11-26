import Foundation
import Testing
@testable import ChatKit

struct ConversationSettingsCodingTests {
    @Test func omittedSettingsAndIntegrationGrantsDefaultToRefusal() throws {
        let decoder = JSONDecoder()
        let settings = try decoder.decode(ConversationSettings.self, from: Data("{}".utf8))
        #expect(settings.permissions.isEmpty)
        #expect(settings.requestToJoin == nil)
        #expect(!settings.canChangeAccess && !settings.canChangeRequestToJoin)
        let integrations = try decoder.decode(ConversationIntegrations.self, from: Data("{}".utf8))
        #expect(integrations.webhooks.isEmpty && !integrations.canCreateWebhook)
        let webhook = try decoder.decode(
            ConversationWebhook.self,
            from: Data(#"{"id":"hook","name":"Builds"}"#.utf8)
        )
        #expect(webhook.allowedActions.isEmpty)
        #expect(!Capabilities().canManageConversationWebhooks)
    }

    @Test func unknownAudienceAndMutationsKeepTheirPayload() throws {
        let decoder = JSONDecoder()
        let permission = try decoder.decode(ConversationPermission.self, from: Data(
            #"{"id":"future","audience":{"type":"future-group","extra":[true]}}"#.utf8
        ))
        #expect(permission.audience.type == "future-group")
        #expect(try decoder
            .decode(JSONValue.self, from: JSONEncoder().encode(permission.audience)) == .object([
                "type": .string("future-group"),
                "extra": .array([.bool(true)])
            ]))
        #expect(!permission.isEditable)
        let payload = Data(#"{"type":"futureSetting","settings":{"value":17},"extra":[true]}"#.utf8)
        let value = try decoder.decode(ConversationMutation.self, from: payload)
        let encoded = try JSONEncoder().encode(value)
        #expect(try decoder.decode(JSONValue.self, from: encoded) == decoder.decode(
            JSONValue.self,
            from: payload
        ))
    }

    @Test func clearingAndWebhookMutationsRoundTripWithExplicitFields() throws {
        let values: [ConversationMutation] = [
            .details(.init(name: "Planning", description: "", guidelines: "", emoji: "")),
            .generateEmail, .setEmailDelivery(false), .deleteEmail,
            .addApp(.init("app")), .removeApp(.init("app")), .setPersonBlocked(.init("peer"), true),
            .convertToSpace(name: "Planning", emoji: "🐾", acknowledgingHistoryChange: true),
            .emoji(""), .settings(.init(requestToJoin: false, permissions: ["manageMembers": .managers])),
            .saveWebhook(id: nil, name: "Builds", avatarURL: ""),
            .saveWebhook(id: "hook", name: "Builds", avatarURL: ""), .deleteWebhook("hook")
        ]
        for value in values {
            #expect(try JSONDecoder()
                .decode(ConversationMutation.self, from: JSONEncoder().encode(value)) == value)
        }
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ConversationMutation.self, from: Data(
                #"{"type":"editWebhook","name":"Builds","avatarURL":""}"#.utf8
            ))
        }
    }
}
