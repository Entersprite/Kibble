#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    extension ConversationPanelsHostedTests {
        /// Info's People table, its bar and its footer, at the sheet's default
        /// and minimum sizes, with members, an invitation and a request.
        @Test func infoPeopleTableRendersAtDefaultAndMinimumSize() async throws {
            let names = ["Ana Lee", "Sam Ortiz", "Kai Rivera", "Mia Chen", "Leo Park", "Noa Fischer"]
            let participants = names.enumerated().map { index, name in
                let first = name.split(separator: " ")[0].lowercased()
                return ConversationParticipant(
                    member: Member(
                        id: .init("p\(index)"), kind: .human, displayName: name,
                        email: index == 2 ? "\(first)@partner.example" : "\(first)@studio.example"
                    ),
                    role: index == 0 ? .owner : index == 1 ? .manager : .member,
                    state: index == 5 ? .requested : index == 4 ? .invited : .joined,
                    allowedActions: index == 5
                        ? ["approveRequest", "rejectRequest"] : ["setRole", "removePerson"],
                    allowedRoles: [.member, .manager, .owner],
                    isExternal: index == 2
                )
            }
            var state = ChatSceneState()
            state.browser.panelTarget = .init("studio")
            state.browser.details = ConversationDetails(
                conversation: Conversation(
                    id: .init("studio"), kind: .space, title: "Design Studio", memberCount: 14
                ),
                membership: .joined, allowedActions: ["addPeople"]
            )
            state.browser.participants = participants
            state.browser.hasMoreParticipants = true
            state.browser.pendingMutation = .setRole(.init("p3"), .manager)
            for size in [NSSize(width: 760, height: 560), NSSize(width: 640, height: 440)] {
                for dark in [false, true] {
                    try await render(
                        ConversationPanelSheet(state: state, browser: actions, openNotifications: nil),
                        dark: dark,
                        name: "info-people-\(Int(size.width))-\(dark ? "dark" : "light")",
                        size: size
                    )
                }
            }
            // Requests at the detail column's narrowest: Decline and Approve fit in Role.
            let details = try #require(state.browser.details)
            try await render(
                ConversationPeopleTable(details: details, state: state, actions: actions, scope: .requests),
                dark: false, name: "info-people-requests", size: NSSize(width: 450, height: 300)
            )
        }

        /// Info for the kinds the per-section renders leave out: a group chat
        /// (People and Details in the sidebar) and a one-to-one chat (People
        /// alone), at the sheet's default and minimum sizes in both
        /// appearances. A space's four sections render in their own tests.
        @Test func infoSheetSectionsRenderInBothAppearances() async throws {
            let people = ["Ana Lee", "Sam Ortiz", "Kai Rivera"].enumerated().map { index, name in
                ConversationParticipant(
                    member: Member(
                        id: .init("g\(index)"), kind: .human, displayName: name,
                        email: "\(name.split(separator: " ")[0].lowercased())@studio.example"
                    ),
                    role: .member, state: .joined, allowedActions: index == 0 ? [] : ["removePerson"]
                )
            }
            let group = ConversationDetails(
                conversation: Conversation(
                    id: .init("lunch"), kind: .groupDirectMessage, title: "Lunch Crew", memberCount: 3
                ),
                membership: .joined, allowedActions: ["details", "rename", "addPeople", "convertToSpace"]
            )
            let direct = ConversationDetails(
                conversation: Conversation(id: .init("sam"), kind: .directMessage, title: "Sam Ortiz"),
                membership: .joined
            )
            for (name, details, participants) in [
                ("group", group, people), ("direct", direct, Array(people.prefix(2)))
            ] {
                var state = ChatSceneState()
                state.browser.panelTarget = details.conversation.id
                state.browser.details = details
                state.browser.participants = participants
                for size in [NSSize(width: 760, height: 560), NSSize(width: 640, height: 440)] {
                    for dark in [false, true] {
                        try await render(
                            ConversationPanelSheet(
                                state: state,
                                browser: actions,
                                openNotifications: { _ in }
                            ),
                            dark: dark,
                            name: "info-\(name)-people-\(Int(size.width))-\(dark ? "dark" : "light")",
                            size: size
                        )
                    }
                }
            }
        }
    }
#endif
