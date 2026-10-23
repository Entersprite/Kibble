import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The Settings section's draft: what Save sends for access, join requests
/// and Who Can, and what it never sends.
struct SettingsDraftTests {
    private static let ids = [
        "viewMembers", "manageMembers", "modifyDetails", "changeHistory", "mentionAll", "manageApps",
        "manageWebhooks"
    ]

    /// The fixture owner's settings: every rule All Members and editable;
    /// only the member list offers Organization.
    private func settings(
        requestToJoin: Bool? = false,
        canChangeAccess: Bool = true,
        override: [String: PermissionAudience] = [:]
    ) -> ConversationSettings {
        ConversationSettings(
            permissions: Self.ids.map { id in
                ConversationPermission(
                    id: id, audience: override[id] ?? .members, isEditable: true,
                    allowedAudiences: id == "viewMembers"
                        ? [.owners, .managers, .members, .organization] : [.owners, .managers, .members]
                )
            },
            requestToJoin: requestToJoin, externalMembersAllowed: false,
            canChangeAccess: canChangeAccess, canChangeRequestToJoin: true
        )
    }

    @Test func untouchedSettingsProduceNoPatch() {
        let draft = SettingsDraft(access: .discoverable, settings: settings())
        #expect(!draft.isDirty)
        #expect(draft.patch() == nil)
    }

    @Test func customRulesAreNeverSent() {
        let current = settings(override: ["mentionAll": .unknown])
        var draft = SettingsDraft(access: .restricted, settings: current)
        #expect(draft.isReadOnly(current.permissions[4]))
        draft.audiences["mentionAll"] = .owners
        draft.audiences["manageApps"] = .owners
        let patch = draft.patch()
        #expect(patch?.permissions == ["manageApps": .owners])
        #expect(patch?.permissions["mentionAll"] == nil)
    }

    @Test func manageMembersCannotExceedViewMembers() {
        var draft = SettingsDraft(access: .restricted, settings: settings())
        #expect(draft.choices(for: "manageMembers") == [.owners, .managers, .members])
        draft.setAudience(.managers, for: "viewMembers")
        #expect(!draft.choices(for: "manageMembers").contains(.members))
        #expect(draft.choices(for: "manageMembers") == [.owners, .managers])
        // Narrowing who can see the list narrows who can manage it with it.
        #expect(draft.audiences["manageMembers"] == .managers)
        #expect(draft.patch()?.permissions == ["viewMembers": .managers, "manageMembers": .managers])
        // Widening "see" leaves "manage" as it is.
        draft.setAudience(.organization, for: "viewMembers")
        #expect(draft.choices(for: "manageMembers") == [.owners, .managers, .members])
        #expect(draft.audiences["manageMembers"] == .managers)
    }

    @Test func changingAccessAloneSendsOnlyAccess() {
        var draft = SettingsDraft(access: .restricted, settings: settings())
        draft.access = .open
        #expect(draft.patch() == ConversationSettingsPatch(access: .open))
        draft.access = .restricted
        #expect(draft.patch() == nil)
    }

    @Test func unknownPermissionIdsHaveNoLabel() {
        #expect(PermissionText.label("future") == nil)
        #expect(PermissionText.label("viewMembers") == "See the member list")
        #expect(PermissionText.label("manageMembers") == "Add and remove people")
        #expect(PermissionText.audience(.managers) == "Owners and Managers")
        #expect(PermissionText.audience(.members) == "All Members")
    }

    // MARK: Beyond the brief

    @Test func openingASpaceTurnsJoinRequestsOff() {
        var draft = SettingsDraft(access: .discoverable, settings: settings(requestToJoin: true))
        draft.access = .open
        // Open doesn't offer requests, and the server refuses Open with them on.
        #expect(draft.patch() == ConversationSettingsPatch(access: .open, requestToJoin: false))
        draft.access = .discoverable
        #expect(draft.patch() == nil)
    }

    @Test func onlyChangeableValuesAreSent() {
        var locked = settings(canChangeAccess: false)
        locked.canChangeRequestToJoin = false
        locked.permissions[2].isEditable = false
        var draft = SettingsDraft(access: .restricted, settings: locked)
        draft.access = .open
        draft.requestToJoin = true
        draft.audiences["modifyDetails"] = .owners
        #expect(draft.patch() == nil)
        #expect(draft.isReadOnly(locked.permissions[2]))
    }

    @Test func customAccessIsReadOnly() {
        var draft = SettingsDraft(access: ConversationAccess("custom"), settings: settings())
        #expect(!draft.canChangeAccess)
        draft.access = .open
        #expect(draft.patch() == nil)
        #expect(!SettingsDraft(access: .unknown, settings: settings()).canChangeAccess)
    }

    @Test func choicesOfferOnlyWhatTheServerAllows() {
        let draft = SettingsDraft(access: .restricted, settings: settings())
        #expect(draft.choices(for: "viewMembers") == [.owners, .managers, .members, .organization])
        #expect(!draft.choices(for: "modifyDetails").contains(.organization))
        #expect(draft.choices(for: "future").isEmpty)
    }

    @Test func rebasingKeepsChoicesAndTakesNewValues() {
        var draft = SettingsDraft(access: .restricted, settings: settings())
        draft.audiences["manageApps"] = .owners
        let reloaded = settings(override: ["manageWebhooks": .managers])
        let next = draft.updated(access: .discoverable, settings: reloaded, isAnswer: false)
        #expect(next.access == .discoverable)
        #expect(next.audiences["manageApps"] == .owners)
        #expect(next.audiences["manageWebhooks"] == .managers)
        #expect(next.patch() == ConversationSettingsPatch(permissions: ["manageApps": .owners]))
        // The saved answer: the change is the server's value now.
        let answer = settings(override: ["manageApps": .owners])
        #expect(!draft.updated(access: .restricted, settings: answer, isAnswer: false).isDirty)
        #expect(!draft.updated(access: .restricted, settings: settings(), isAnswer: true).isDirty)
    }
}
