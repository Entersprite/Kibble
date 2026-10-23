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
        // Both are All Members: the member list can't go narrower than its managers.
        #expect(draft.choices(for: "viewMembers") == [.members, .organization])
        #expect(draft.isMemberListHeldByManageMembers)
        draft.setAudience(.managers, for: "manageMembers")
        #expect(draft.choices(for: "viewMembers") == [.managers, .members, .organization])
        draft.setAudience(.managers, for: "viewMembers")
        #expect(!draft.choices(for: "manageMembers").contains(.members))
        #expect(draft.choices(for: "manageMembers") == [.owners, .managers])
        #expect(draft.patch()?.permissions == ["manageMembers": .managers, "viewMembers": .managers])
    }

    @Test func changingOneRuleNeverChangesAnother() {
        var draft = SettingsDraft(access: .restricted, settings: settings())
        draft.setAudience(.organization, for: "viewMembers")
        #expect(draft.audiences["manageMembers"] == .members)
        #expect(draft.patch()?.permissions == ["viewMembers": .organization])
        // Narrowing back below its managers isn't offered, so nothing else moves.
        #expect(!draft.choices(for: "viewMembers").contains(.managers))
        let readOnly = SettingsDraft(
            access: .restricted, settings: settings(override: ["manageMembers": .managers])
        )
        #expect(readOnly.choices(for: "viewMembers") == [.managers, .members, .organization])
        #expect(readOnly.isMemberListHeldByManageMembers)
    }

    @Test func aRuleTheServerReportsInconsistentlyIsText() {
        // Managers wider than the member list: no menu can show the value.
        let current = settings(override: ["viewMembers": .managers])
        let draft = SettingsDraft(access: .restricted, settings: current)
        #expect(!draft.choices(for: "manageMembers").contains(.members))
        #expect(draft.isReadOnly(current.permissions[1]))
        #expect(draft.patch() == nil)
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
        #expect(!draft.turnsRequestsOff)
        draft.access = .open
        // Open doesn't offer requests, and the server refuses Open with them on.
        #expect(draft.turnsRequestsOff)
        #expect(draft.patch() == ConversationSettingsPatch(access: .open, requestToJoin: false))
        draft.access = .discoverable
        #expect(!draft.turnsRequestsOff)
        #expect(draft.patch() == nil)
        // Requests already off: nothing to say, nothing extra sent.
        var off = SettingsDraft(access: .discoverable, settings: settings(requestToJoin: false))
        off.access = .open
        #expect(!off.turnsRequestsOff)
        #expect(off.patch() == ConversationSettingsPatch(access: .open))
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
        let draft = SettingsDraft(
            access: .restricted,
            settings: settings(override: ["manageMembers": .owners])
        )
        #expect(draft.choices(for: "viewMembers") == [.owners, .managers, .members, .organization])
        #expect(!draft.isMemberListHeldByManageMembers)
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

    @Test func rebasingDropsChoicesTheReloadNoLongerAllows() {
        var draft = SettingsDraft(access: .restricted, settings: settings())
        draft.access = .open
        draft.requestToJoin = true
        draft.audiences["manageApps"] = .owners
        draft.audiences["manageWebhooks"] = .owners
        var locked = settings()
        locked.canChangeAccess = false
        locked.canChangeRequestToJoin = false
        locked.permissions[5].isEditable = false
        let next = draft.updated(access: .discoverable, settings: locked, isAnswer: false)
        #expect(next.access == .discoverable)
        #expect(next.requestToJoin == false)
        #expect(next.audiences["manageApps"] == .members)
        #expect(next.audiences["manageWebhooks"] == .owners)
        #expect(next.patch() == ConversationSettingsPatch(permissions: ["manageWebhooks": .owners]))
    }

    @Test func openIsUnavailableWhileRequestsCantBeTurnedOff() {
        var fixed = settings(requestToJoin: true)
        fixed.canChangeRequestToJoin = false
        var draft = SettingsDraft(access: .discoverable, settings: fixed)
        #expect(!draft.isOpenAvailable)
        #expect(!draft.isAvailable(.open))
        #expect(draft.isAvailable(.restricted))
        draft.access = .open
        // Save can't turn requests off, so it promises nothing and sends nothing.
        #expect(!draft.turnsRequestsOff)
        #expect(draft.patch() == nil)
        // Requests changeable: Open is offered and Save says it turns them off.
        var free = SettingsDraft(access: .discoverable, settings: settings(requestToJoin: true))
        #expect(free.isOpenAvailable)
        free.access = .open
        #expect(free.turnsRequestsOff)
    }

    @Test func rebasingDropsOpenAndANarrowerMemberListTheReloadRefuses() {
        var draft = SettingsDraft(access: .discoverable, settings: settings(requestToJoin: false))
        draft.access = .open
        var requests = settings(requestToJoin: true)
        requests.canChangeRequestToJoin = false
        #expect(draft.updated(access: .discoverable, settings: requests, isAnswer: false)
            .access == .discoverable)

        var narrow = SettingsDraft(
            access: .restricted, settings: settings(override: ["manageMembers": .owners])
        )
        narrow.setAudience(.managers, for: "viewMembers")
        let wider = settings(override: ["manageMembers": .members])
        let next = narrow.updated(access: .restricted, settings: wider, isAnswer: false)
        #expect(next.audiences["viewMembers"] == .members)
        #expect(next.patch() == nil)
    }
}
