#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    extension ConversationPanelsHostedTests {
        private static let ruleIDs = [
            "viewMembers", "manageMembers", "modifyDetails", "changeHistory", "mentionAll", "manageApps",
            "manageWebhooks"
        ]

        private func space(
            _ settings: ConversationSettings, access: ConversationAccess
        ) -> ConversationDetails {
            ConversationDetails(
                conversation: Conversation(
                    id: .init("studio"), kind: .space, title: "Design Studio Crew", memberCount: 14
                ),
                access: access,
                membership: .joined,
                allowedActions: ["settings"],
                settings: settings
            )
        }

        /// Info's Settings for an owner: access radios with their
        /// explanations, the join-requests switch, external people, Who Can
        /// with a custom rule, and Space Email with an address. Default and
        /// minimum sizes, top and scrolled to the end, both appearances.
        @Test func infoSettingsRendersForASpaceOwner() async throws {
            let audiences: [String: PermissionAudience] = [
                "manageMembers": .managers, "modifyDetails": .managers, "mentionAll": .unknown,
                "manageApps": .owners, "manageWebhooks": .owners
            ]
            let settings = ConversationSettings(
                permissions: Self.ruleIDs.map { id in
                    ConversationPermission(
                        id: id, audience: audiences[id] ?? .members, isEditable: true,
                        allowedAudiences: id == "viewMembers"
                            ? [.owners, .managers, .members, .organization] : [.owners, .managers, .members]
                    )
                },
                requestToJoin: false, externalMembersAllowed: true,
                canChangeAccess: true, canChangeRequestToJoin: true
            )
            let details = space(settings, access: .discoverable)
            var state = ChatSceneState()
            state.capabilities = Capabilities(extendedFlags: ["conversationEmail"])
            state.browser.panelTarget = details.conversation.id
            state.browser.details = details
            state.browser.email = ConversationEmail(
                address: "design-studio-x7k@example.test", deliveryEnabled: true,
                canGenerate: false, canChangeDelivery: true, canDelete: true
            )
            for size in [NSSize(width: 760, height: 560), NSSize(width: 640, height: 440)] {
                for dark in [false, true] {
                    for scrolled in [false, true] {
                        try await render(
                            ConversationInfoSheet(
                                details: details, state: state, actions: actions, media: nil,
                                openNotifications: nil, section: .settings
                            ),
                            dark: dark,
                            name: "info-settings-space-\(Int(size.width))-\(dark ? "dark" : "light")"
                                + (scrolled ? "-end" : ""),
                            size: size,
                            scrolledToEnd: scrolled
                        )
                    }
                }
            }
        }

        /// A member's view: a custom access mode and rules as text, the
        /// switch disabled, and Create Email Address with a delivery change
        /// pending elsewhere absent.
        @Test func infoSettingsRendersReadOnlyRulesAndCreateEmail() async throws {
            let settings = ConversationSettings(
                permissions: Self.ruleIDs.map { id in
                    ConversationPermission(id: id, audience: id == "mentionAll" ? .unknown : .members)
                },
                requestToJoin: true, externalMembersAllowed: false
            )
            let details = space(settings, access: ConversationAccess("custom"))
            var state = ChatSceneState()
            state.capabilities = Capabilities(extendedFlags: ["conversationEmail"])
            state.browser.panelTarget = details.conversation.id
            state.browser.details = details
            state.browser.email = ConversationEmail(canGenerate: true)
            state.browser.pendingMutation = .generateEmail
            for scrolled in [false, true] {
                try await render(
                    ConversationInfoSheet(
                        details: details, state: state, actions: actions, media: nil,
                        openNotifications: nil, section: .settings
                    ),
                    dark: false,
                    name: "info-settings-readonly-760-light" + (scrolled ? "-end" : ""),
                    size: NSSize(width: 760, height: 560),
                    scrolledToEnd: scrolled
                )
            }
        }

        /// Requests on and unchangeable: Open is offered disabled, with a line why.
        @Test func infoSettingsRendersOpenUnavailable() async throws {
            let settings = ConversationSettings(
                permissions: [], requestToJoin: true, canChangeAccess: true, canChangeRequestToJoin: false
            )
            let details = space(settings, access: .discoverable)
            var state = ChatSceneState()
            state.browser.panelTarget = details.conversation.id
            state.browser.details = details
            try await render(
                ConversationInfoSheet(
                    details: details, state: state, actions: actions, media: nil,
                    openNotifications: nil, section: .settings
                ),
                dark: false, name: "info-settings-open-unavailable-760-light",
                size: NSSize(width: 760, height: 560)
            )
        }
    }
#endif
