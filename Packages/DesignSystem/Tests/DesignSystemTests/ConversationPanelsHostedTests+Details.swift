#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    extension ConversationPanelsHostedTests {
        /// Info's Details for a space (emoji, name, description, guidelines,
        /// then notifications and leaving) and for a group chat (name and
        /// Convert to Space…), at the sheet's default and minimum sizes.
        @Test func infoDetailsRendersForASpaceAndAGroupChat() async throws {
            let limits = ["name": 128, "description": 150, "guidelines": 5000]
            let space = ConversationDetails(
                conversation: Conversation(
                    id: .init("studio"), kind: .space, title: "Design Studio Crew", memberCount: 14
                ),
                description: "Where the studio shares work in progress and reviews.",
                membership: .joined,
                allowedActions: [
                    "details", "rename", "description", "guidelines", "emoji", "leave", "deleteSpace"
                ],
                guidelines: "Post drafts in threads. Tag reviewers with @mentions. No client files here.",
                settings: ConversationSettings(emoji: "🎨"),
                fieldLimits: limits
            )
            let group = ConversationDetails(
                conversation: Conversation(
                    id: .init("lunch"), kind: .groupDirectMessage, title: "Lunch Crew", memberCount: 4
                ),
                membership: .joined,
                allowedActions: ["details", "rename", "convertToSpace", "leave"],
                fieldLimits: limits
            )
            let media = ChatSceneActions(reactions: ReactionActions(toggle: { _, _, _ in }))
            for (name, details) in [("space", space), ("group", group)] {
                var state = ChatSceneState()
                state.browser.panelTarget = details.conversation.id
                state.browser.details = details
                for size in [NSSize(width: 760, height: 560), NSSize(width: 640, height: 440)] {
                    for dark in [false, true] {
                        try await render(
                            ConversationInfoSheet(
                                details: details, state: state, actions: actions, media: media,
                                openNotifications: { _ in }, section: .details
                            ),
                            dark: dark,
                            name: "info-details-\(name)-\(Int(size.width))-\(dark ? "dark" : "light")",
                            size: size
                        )
                    }
                }
            }
        }

        /// Convert to Space over a group chat's Info, with LocalBridge's
        /// consequences (one confirmed line, the rest unknown, acknowledgement
        /// required): loaded in both appearances, then loading, a failed read,
        /// and a refused Convert being checked.
        @Test func convertToSpaceRendersLocalBridgeConsequences() async throws {
            let group = ConversationDetails(
                conversation: Conversation(
                    id: .init("lunch"), kind: .groupDirectMessage, title: "Lunch Crew", memberCount: 4
                ),
                membership: .joined,
                allowedActions: ["details", "rename", "convertToSpace", "leave"],
                fieldLimits: ["name": 128]
            )
            let localBridge = ConversionConsequences(
                items: [ConversionConsequence(topic: .sameConversation, outcome: .kept)]
                    + [
                        ConversionTopic.membership,
                        .messages,
                        .history,
                        .invitations,
                        .integrations,
                        .externalPeople,
                        .undo
                    ]
                    .map { ConversionConsequence(topic: $0, outcome: .unknown) },
                requiresHistoryAcknowledgement: true
            )
            let media = ReactionActions(toggle: { _, _, _ in })
            var state = ChatSceneState()
            state.browser.panelTarget = group.conversation.id
            state.browser.details = group
            state.browser.conversion = localBridge
            let size = NSSize(width: 460, height: 400)
            for dark in [false, true] {
                try await render(
                    ConvertToSpaceSheet(details: group, state: state, actions: actions, reactions: media),
                    dark: dark, name: "convert-to-space-\(dark ? "dark" : "light")", size: size
                )
            }
            try await renderConversionStates(group, state, reactions: media, size: size)
        }

        /// Loading, a failed read with Try Again, and the details read again after a Convert.
        private func renderConversionStates(
            _ group: ConversationDetails, _ state: ChatSceneState, reactions media: ReactionActions,
            size: NSSize
        ) async throws {
            var loading = state
            loading.browser.conversion = nil
            loading.browser.isLoadingConversion = true
            try await render(
                ConvertToSpaceSheet(details: group, state: loading, actions: actions, reactions: nil),
                dark: false, name: "convert-to-space-loading", size: size
            )
            loading.browser.isLoadingConversion = false
            loading.browser.conversionError = "The conversion details couldn’t be loaded."
            try await render(
                ConvertToSpaceSheet(details: group, state: loading, actions: actions, reactions: nil),
                dark: true, name: "convert-to-space-load-failed", size: size
            )
            var checking = state
            checking.browser.needsReconciliation = true
            try await render(
                ConvertToSpaceSheet(details: group, state: checking, actions: actions, reactions: media),
                dark: false, name: "convert-to-space-checking", size: size
            )
        }
    }
#endif
