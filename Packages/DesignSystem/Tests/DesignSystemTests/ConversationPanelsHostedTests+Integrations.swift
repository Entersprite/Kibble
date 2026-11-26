#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    extension ConversationPanelsHostedTests {
        private var studio: ConversationDetails {
            ConversationDetails(
                conversation: Conversation(
                    id: .init("studio"), kind: .space, title: "Design Studio Crew", memberCount: 14
                ),
                membership: .joined,
                allowedActions: ["addApp", "removeApp", "createWebhook", "editWebhook", "deleteWebhook"]
            )
        }

        private var populated: ConversationIntegrations {
            let apps = [
                ("standup", "Standup Bot", "Posts the daily standup and collects everyone’s answers."),
                ("release", "Release Notes", "Announces new builds")
            ].map { id, name, description in
                ConversationApp(
                    member: Member(id: .init(id), kind: .app, displayName: name),
                    description: description, allowedActions: ["message", "removeApp"]
                )
            }
            return ConversationIntegrations(
                webhooks: [
                    ConversationWebhook(
                        id: "w1", name: "CI Alerts", allowedActions: ["editWebhook", "deleteWebhook"]
                    ),
                    ConversationWebhook(
                        id: "w2", name: "Deploys",
                        avatarURL: URL(string: "https://example.test/deploys.png"),
                        allowedActions: ["editWebhook", "deleteWebhook"]
                    )
                ],
                canCreateWebhook: true,
                apps: apps,
                canAddApps: true
            )
        }

        /// Info's Integrations with both groups listed, and with both empty,
        /// at the sheet's default and minimum sizes in both appearances.
        @Test func infoIntegrationsRendersBothGroupsListedAndEmpty() async throws {
            var state = ChatSceneState()
            state.capabilities = Capabilities(extendedFlags: ["conversationApps", "conversationWebhooks"])
            state.browser.panelTarget = studio.conversation.id
            state.browser.details = studio
            for (name, integrations) in [
                ("listed", populated),
                ("empty", ConversationIntegrations(canCreateWebhook: true, canAddApps: true))
            ] {
                state.browser.integrations = integrations
                for size in [NSSize(width: 760, height: 560), NSSize(width: 640, height: 440)] {
                    for dark in [false, true] {
                        try await render(
                            ConversationInfoSheet(
                                details: studio, state: state, actions: actions, media: nil,
                                openNotifications: nil, section: .integrations
                            ),
                            dark: dark,
                            name: "info-integrations-\(name)-\(Int(size.width))-\(dark ? "dark" : "light")",
                            size: size
                        )
                    }
                }
            }
        }

        /// A refused remove, delete and add, each beside what failed, with
        /// the reload a refused write needs.
        @Test func infoIntegrationsRendersRefusalsBesideWhatFailed() async throws {
            var state = ChatSceneState()
            state.capabilities = Capabilities(extendedFlags: ["conversationApps", "conversationWebhooks"])
            state.browser.panelTarget = studio.conversation.id
            state.browser.details = studio
            state.browser.integrations = populated
            state.browser.panelError = "You can’t change this space’s integrations."
            state.browser.needsReconciliation = true
            for (name, sent) in [
                ("remove", ConversationMutation.removeApp(.init("release"))),
                ("delete", .deleteWebhook("w1")),
                ("add", .addApp(.init("poll")))
            ] {
                try await render(
                    ConversationIntegrationsForm(details: studio, state: state, actions: actions, sent: sent),
                    dark: name == "delete",
                    name: "info-integrations-refused-\(name)",
                    size: NSSize(width: 760, height: 560)
                )
            }
        }

        /// The webhook editor and the app picker, the small sheets over Integrations.
        @Test func webhookEditorAndAddAppRender() async throws {
            var state = ChatSceneState()
            state.capabilities = Capabilities(extendedFlags: ["conversationApps", "conversationWebhooks"])
            state.browser.panelTarget = studio.conversation.id
            state.browser.details = studio
            state.browser.integrations = populated
            state.browser.appResults = populated.apps + [ConversationApp(
                member: Member(id: .init("poll"), kind: .app, displayName: "Poll"),
                description: "Ask a quick question.", allowedActions: ["addApp"]
            )]
            let webhook = ConversationWebhook(id: "w1", name: "CI Alerts", allowedActions: ["editWebhook"])
            for dark in [false, true] {
                try await render(
                    WebhookEditorSheet(
                        webhook: dark ? webhook : nil, conversationName: "Design Studio Crew",
                        state: state, actions: actions
                    ),
                    dark: dark, name: "webhook-editor-\(dark ? "edit-dark" : "new-light")",
                    size: NSSize(width: 420, height: 270)
                )
                try await render(
                    AddAppSheet(
                        conversationName: "Design Studio Crew", state: state, actions: actions, add: { _ in }
                    ),
                    dark: dark, name: "add-app-\(dark ? "dark" : "light")",
                    size: NSSize(width: 420, height: 440)
                )
            }
        }
    }
#endif
