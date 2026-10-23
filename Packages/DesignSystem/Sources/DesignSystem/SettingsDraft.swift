import ChatKit
import Foundation

/// The Settings section's unsaved edits to a space's access, join requests
/// and Who Can rules, beside the values they started from.
///
/// Save sends only what changed and what the server lets this person
/// change. A rule Kibble can't represent (a custom audience, one outside the
/// row's offered audiences) is read-only and never sent, so saving leaves it
/// as it is. Who can add and remove people is never wider than who can see
/// the member list.
struct SettingsDraft: Equatable {
    var access: ConversationAccess
    var requestToJoin: Bool?
    /// The chosen audience of each rule, by permission ID.
    var audiences: [String: PermissionAudience]

    /// The rules as the server supplied them, in its order.
    let permissions: [ConversationPermission]
    /// Whether the access mode can be changed here: the server allows it and
    /// the current mode is one of Private, Discoverable and Open.
    let canChangeAccess: Bool
    let canChangeRequestToJoin: Bool
    private let originalAccess: ConversationAccess
    private let originalRequestToJoin: Bool?

    /// The access modes offered, in the order shown.
    static let accessModes: [ConversationAccess] = [.restricted, .discoverable, .open]
    /// Audiences narrowest first.
    static let audienceOrder: [PermissionAudience] = [.owners, .managers, .members, .organization]

    private static let viewMembers = "viewMembers"
    private static let manageMembers = "manageMembers"

    init(access: ConversationAccess, settings: ConversationSettings) {
        let access = Self.standard(access, among: Self.accessModes)
        let permissions = settings.permissions.map { permission in
            var permission = permission
            permission.audience = Self.standard(permission.audience, among: Self.audienceOrder)
            permission.allowedAudiences = permission.allowedAudiences.map {
                Self.standard($0, among: Self.audienceOrder)
            }
            return permission
        }
        self.access = access
        originalAccess = access
        requestToJoin = settings.requestToJoin
        originalRequestToJoin = settings.requestToJoin
        self.permissions = permissions
        audiences = Dictionary(
            permissions.map { ($0.id, $0.audience) }, uniquingKeysWith: { first, _ in first }
        )
        canChangeAccess = settings.canChangeAccess && Self.accessModes.contains(access)
        canChangeRequestToJoin = settings.canChangeRequestToJoin
    }

    init(_ details: ConversationDetails) {
        self.init(access: details.access, settings: details.settings ?? ConversationSettings())
    }

    /// The known token of the same type, so a token carrying extra fields still matches.
    private static func standard<Domain>(
        _ token: ConversationToken<Domain>, among known: [ConversationToken<Domain>]
    ) -> ConversationToken<Domain> {
        known.first { $0.type == token.type } ?? token
    }

    private static func rank(_ audience: PermissionAudience?) -> Int? {
        audience.flatMap { audienceOrder.firstIndex(of: $0) }
    }

    var isDirty: Bool {
        patch() != nil
    }

    /// Whether Open is chosen: it offers no join requests.
    var isOpen: Bool {
        access == .open
    }

    /// The join-requests value Save would leave: Open turns requests off.
    private var effectiveRequestToJoin: Bool? {
        isOpen ? requestToJoin.map { _ in false } : requestToJoin
    }

    /// Whether Save turns join requests off because Open is chosen: they were
    /// on, Open doesn't take them, and this person can turn them off. The
    /// form says so in place of the switch.
    var turnsRequestsOff: Bool {
        isOpen && originalRequestToJoin == true && canChangeRequestToJoin
    }

    /// Whether Open can be chosen: not while requests to join are on and
    /// this person can't turn them off, because the server refuses Open then.
    var isOpenAvailable: Bool {
        requestToJoin != true || canChangeRequestToJoin
    }

    /// Whether an access mode can be chosen now.
    func isAvailable(_ mode: ConversationAccess) -> Bool {
        mode != .open || isOpenAvailable
    }

    /// The audiences a rule's menu offers, narrowest first: those the server
    /// allows for it, never letting who can add and remove people be wider
    /// than who can see the member list. Each side is limited by the other's
    /// draft value, so neither change rewrites the other rule; without a
    /// known value on the other side there is nothing safe to offer.
    func choices(for permissionID: String) -> [PermissionAudience] {
        let choices = allowedChoices(for: permissionID)
        switch permissionID {
        case Self.manageMembers:
            guard let widest = Self.rank(audiences[Self.viewMembers]) else { return [] }
            return choices.filter { (Self.rank($0) ?? .max) <= widest }
        case Self.viewMembers:
            guard let narrowest = Self.rank(audiences[Self.manageMembers]) else { return [] }
            return choices.filter { (Self.rank($0) ?? -1) >= narrowest }
        default:
            return choices
        }
    }

    /// The known audiences the server offers for a rule, narrowest first.
    private func allowedChoices(for permissionID: String) -> [PermissionAudience] {
        guard let permission = permissions.first(where: { $0.id == permissionID }) else { return [] }
        return Self.audienceOrder.filter(permission.allowedAudiences.contains)
    }

    /// Whether the member list offers fewer audiences than the server allows
    /// because of who can add and remove people: it can't go narrower first.
    var isMemberListHeldByManageMembers: Bool {
        let offered = choices(for: Self.viewMembers)
        return !offered.isEmpty && offered.count < allowedChoices(for: Self.viewMembers).count
    }

    /// Whether a rule shows as text: the server doesn't let it change, it is
    /// a custom rule, its audience isn't one the server offers for it, or its
    /// current value isn't among its choices (the server's own values break
    /// the member-list rule, or the other side's value is unknown).
    func isReadOnly(_ permission: ConversationPermission) -> Bool {
        if isLocked(permission) {
            return true
        }
        let current = audiences[permission.id] ?? Self.standard(
            permission.audience,
            among: Self.audienceOrder
        )
        return !choices(for: permission.id).contains(current)
    }

    /// Read-only whatever the draft holds: not editable, a custom rule, or
    /// an audience the server doesn't offer for it.
    private func isLocked(_ permission: ConversationPermission) -> Bool {
        let audience = Self.standard(permission.audience, among: Self.audienceOrder)
        let allowed = permission.allowedAudiences.map { Self.standard($0, among: Self.audienceOrder) }
        return !permission.isEditable || Self.rank(audience) == nil || !allowed.contains(audience)
    }

    /// Chooses a rule's audience. It never changes another rule.
    mutating func setAudience(_ audience: PermissionAudience, for permissionID: String) {
        audiences[permissionID] = audience
    }

    /// The changed, changeable values; nil when there is nothing to send.
    func patch() -> ConversationSettingsPatch? {
        var patch = ConversationSettingsPatch()
        if canChangeAccess, access != originalAccess, Self.accessModes.contains(access), isAvailable(access) {
            patch.access = access
        }
        if canChangeRequestToJoin, let request = effectiveRequestToJoin, request != originalRequestToJoin {
            patch.requestToJoin = request
        }
        for permission in permissions where !isReadOnly(permission) {
            if let audience = audiences[permission.id], audience != permission.audience,
               permission.allowedAudiences.contains(audience) {
                patch.permissions[permission.id] = audience
            }
        }
        return patch == ConversationSettingsPatch() ? nil : patch
    }

    /// The draft once `details` changes: from scratch when it is the saved
    /// answer, else rebased so the person's choices stay.
    func updated(to details: ConversationDetails, isAnswer: Bool) -> SettingsDraft {
        updated(
            access: details.access, settings: details.settings ?? ConversationSettings(), isAnswer: isAnswer
        )
    }

    func updated(
        access: ConversationAccess, settings: ConversationSettings, isAnswer: Bool
    ) -> SettingsDraft {
        isAnswer
            ? SettingsDraft(access: access, settings: settings)
            : rebased(access: access, settings: settings)
    }

    /// This draft over settings read again: what the person changed stays,
    /// everything else takes the new values. When the reload is the saved
    /// answer, the choices match it and the draft is clean.
    func rebased(access newAccess: ConversationAccess, settings: ConversationSettings) -> SettingsDraft {
        var next = SettingsDraft(access: newAccess, settings: settings)
        // A choice carries over only where the reloaded settings still let it change.
        if access != originalAccess, next.canChangeAccess, Self.accessModes.contains(access),
           next.isAvailable(access) {
            next.access = access
        }
        if requestToJoin != originalRequestToJoin, next.canChangeRequestToJoin {
            next.requestToJoin = requestToJoin
        }
        for permission in permissions {
            guard let audience = audiences[permission.id], audience != permission.audience,
                  let reloaded = next.permissions.first(where: { $0.id == permission.id }),
                  !next.isLocked(reloaded), reloaded.allowedAudiences.contains(audience) else { continue }
            next.audiences[permission.id] = audience
        }
        // A carried member list narrower than its managers would be refused.
        if let view = Self.rank(next.audiences[Self.viewMembers]),
           let manage = Self.rank(next.audiences[Self.manageMembers]), view < manage {
            next.audiences[Self.viewMembers] = next.permissions
                .first { $0.id == Self.viewMembers }?.audience
        }
        return next
    }
}

/// Plain words for a space's Who Can rules and access modes.
enum PermissionText {
    /// A rule's row label; nil for a rule Kibble doesn't know, whose row is hidden.
    static func label(_ id: String) -> String? {
        switch id {
        case "viewMembers": "See the member list"
        case "manageMembers": "Add and remove people"
        case "modifyDetails": "Change name and details"
        case "changeHistory": "Turn history on or off"
        case "mentionAll": "Use @all"
        case "manageApps": "Manage apps"
        case "manageWebhooks": "Manage webhooks"
        default: nil
        }
    }

    static func audience(_ audience: PermissionAudience) -> String {
        switch audience.type {
        case PermissionAudience.owners.type: "Owners"
        case PermissionAudience.managers.type: "Owners and Managers"
        case PermissionAudience.members.type: "All Members"
        case PermissionAudience.organization.type: "Organization"
        default: "Custom rule"
        }
    }

    /// An access mode's name; any other mode is a custom rule.
    static func access(_ access: ConversationAccess) -> String {
        switch access.type {
        case ConversationAccess.restricted.type: "Private"
        case ConversationAccess.discoverable.type: "Discoverable"
        case ConversationAccess.open.type: "Open"
        default: "Custom rule"
        }
    }

    /// One line on who outside the space can find and join it in each mode.
    static func accessExplanation(_ access: ConversationAccess) -> String? {
        switch access.type {
        case ConversationAccess.restricted.type: "People in your organization can’t find it or join it."
        case ConversationAccess.discoverable.type:
            "People in your organization can find it but can’t join it."
        case ConversationAccess.open.type: "People in your organization can find it and join it."
        default: nil
        }
    }
}
