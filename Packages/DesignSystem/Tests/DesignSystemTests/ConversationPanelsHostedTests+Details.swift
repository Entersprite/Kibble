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
    }
#endif
