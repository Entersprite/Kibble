import ChatKit
import SwiftUI

/// One connected account as the account panel shows it. Values only: the
/// client decides every field, and the panel draws them.
public struct AccountPanelAccount: Identifiable {
    public enum Problem: Equatable, Sendable {
        /// Signed out by the provider; Reconnect signs in again.
        case signInRequired
        /// Could not start or recover; Retry tries again.
        case failed
    }

    public let id: String
    /// What sets the account apart: its managing domain, "Personal" or an email.
    public let label: String
    /// Who is signed in, for the pill and VoiceOver.
    public let name: String?
    public let email: String?
    /// The domain that manages the account, for its help text.
    public let managedBy: String?
    public let unread: Int
    public let problem: Problem?
    public let isEnabled: Bool
    /// The account's own member and what is known about them, for its avatar.
    public let me: Member.ID
    public let directory: [Member.ID: Member]
    /// Loads that account's own photos; `nil` while it is not running, and
    /// the avatar falls back to initials.
    public let imageLoader: SceneImageLoader?

    public init(
        id: String, label: String, name: String?, email: String?, managedBy: String?,
        unread: Int, problem: Problem?, isEnabled: Bool,
        me: Member.ID, directory: [Member.ID: Member], imageLoader: SceneImageLoader?
    ) {
        self.id = id
        self.label = label
        self.name = name
        self.email = email
        self.managedBy = managedBy
        self.unread = unread
        self.problem = problem
        self.isEnabled = isEnabled
        self.me = me
        self.directory = directory
        self.imageLoader = imageLoader
    }
}

/// A sign-in that was started and not finished. Choosing it resumes it.
public struct AccountPanelPendingSignIn: Identifiable, Equatable, Sendable {
    public let id: String
    public init(id: String) {
        self.id = id
    }
}

public struct AccountPanelState {
    public var accounts: [AccountPanelAccount]
    public var pendingSignIns: [AccountPanelPendingSignIn]
    public var selectedID: String?
    /// The selected account's scene while it runs: its status, presence and
    /// marks. `nil` while the selected account is not running.
    public var scene: ChatSceneState?

    public init(
        accounts: [AccountPanelAccount], pendingSignIns: [AccountPanelPendingSignIn] = [],
        selectedID: String?, scene: ChatSceneState?
    ) {
        self.accounts = accounts
        self.pendingSignIns = pendingSignIns
        self.selectedID = selectedID
        self.scene = scene
    }

    var selected: AccountPanelAccount? {
        accounts.first { $0.id == selectedID }
    }

    /// One account needs no label: there is nothing to tell it apart from.
    var showsLabels: Bool {
        accounts.count > 1
    }

    /// Unread conversations in every enabled account except the one on screen.
    var othersUnread: Int {
        accounts.filter { $0.id != selectedID && $0.isEnabled }.reduce(0) { $0 + $1.unread }
    }

    var othersHaveProblem: Bool {
        accounts.contains { $0.id != selectedID && $0.problem != nil }
    }
}

/// What the account panel can do. Each optional is drawn only when offered,
/// and every account action names its account, captured when it is chosen.
public struct AccountPanelActions {
    public var select: (String) -> Void
    public var add: (() -> Void)?
    public var resumeSignIn: ((String) -> Void)?
    public var manage: (() -> Void)?
    /// Signs in again after `.signInRequired`, retries after `.failed`.
    public var reconnect: ((String) -> Void)?
    public var setEnabled: ((String, Bool) -> Void)?
    /// Keeps the account and its settings until it signs in again as itself.
    public var signOut: ((String) -> Void)?
    /// Removes the account with its settings.
    public var remove: ((String) -> Void)?
    public var showSettings: (() -> Void)?
    /// The selected account's own status actions, bound to that account.
    public var setAvailability: ((Availability) -> Void)?
    public var setStatus: ((MemberStatus?) -> Void)?
    public var reactions: ReactionActions?

    public init(
        select: @escaping (String) -> Void,
        add: (() -> Void)? = nil,
        resumeSignIn: ((String) -> Void)? = nil,
        manage: (() -> Void)? = nil,
        reconnect: ((String) -> Void)? = nil,
        setEnabled: ((String, Bool) -> Void)? = nil,
        signOut: ((String) -> Void)? = nil,
        remove: ((String) -> Void)? = nil,
        showSettings: (() -> Void)? = nil,
        setAvailability: ((Availability) -> Void)? = nil,
        setStatus: ((MemberStatus?) -> Void)? = nil,
        reactions: ReactionActions? = nil
    ) {
        self.select = select
        self.add = add
        self.resumeSignIn = resumeSignIn
        self.manage = manage
        self.reconnect = reconnect
        self.setEnabled = setEnabled
        self.signOut = signOut
        self.remove = remove
        self.showSettings = showSettings
        self.setAvailability = setAvailability
        self.setStatus = setStatus
        self.reactions = reactions
    }
}
