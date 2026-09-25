import ChatKit
import DesignSystem
import Foundation
import Observation
import SyncEngine

extension AppEnvironment {
    /// Points the engine's receipts gate at the settings, now and on every
    /// change. `nil` settings - no account - withholds (spec §3.1).
    func beginSettingsSession(engine: SyncEngine) {
        let gate = engine.readReceipts
        receiptGate = gate
        let apply: @MainActor (NotificationSettings?) -> Void = { current in
            gate.set(current.map(ReadReceiptPolicy.resolve) ?? .withhold)
        }
        apply(settings.account == nil ? nil : settings.settings)
        settings.onChange = apply
    }

    /// Switches the settings to whoever the model says is signed in, the moment
    /// it says so - from the store on a returning launch, from
    /// `ChatEvent.selfIdentified` otherwise.
    ///
    /// The cancellation check is for one value already queued when sign-out
    /// cancels this task: without it, that `me` could land after
    /// `switchAccount(to: nil)` and sign the settings back in to the account
    /// that just left.
    func followIdentity(of model: ChatSessionModel) {
        identityTask?.cancel()
        identityTask = Task { [weak self] in
            for await me in Observations({ model.me }) {
                guard !Task.isCancelled else { return }
                self?.settings.switchAccount(to: me)
            }
        }
    }
}

public extension AppEnvironment {
    /// The Dock and menu-bar count: unread conversations whose rule counts them.
    var badgeCount: Int {
        guard case let .running(model) = phase else { return 0 }
        return settings.settings.badgeCount(of: model.conversations)
    }
}

public extension AppEnvironment {
    var notificationSettingsState: NotificationSettingsState {
        let current = settings.settings
        var sections: [SectionKey: NotificationRule] = [:]
        var inherited: [SectionKey: ResolvedRule] = [:]
        var resolved: [SectionKey: ResolvedRule] = [:]
        for section in SectionKey.ruleSections {
            sections[section] = current.rule(for: .section(section)) ?? NotificationRule()
            inherited[section] = current.inherited(bySection: section)
            resolved[section] = current.resolvedSection(section)
        }
        return NotificationSettingsState(
            isAvailable: settings.account != nil,
            globalRule: current.rule(for: .global) ?? NotificationRule(),
            global: current.resolvedGlobal,
            sections: sections,
            sectionInherited: inherited,
            sectionResolved: resolved,
            lastError: settings.lastError,
            pauseStatus: pauseStatus,
            conversations: current.customizedConversations.map(conversationRuleState(for:))
        )
    }

    func notificationSettingsActions(openSystemSettings: (() -> Void)?) -> NotificationSettingsActions {
        NotificationSettingsActions(
            updateGlobal: { [weak self] in self?.settings.update($0, for: .global) },
            updateSection: { [weak self] section, rule in
                self?.settings.update(rule, for: .section(section))
            },
            openSystemSettings: openSystemSettings,
            pause: { [weak self] in self?.pauseNotifications($0) },
            resume: { [weak self] in self?.resumeNotifications() },
            updateConversation: { [weak self] id, rule in
                self?.settings.update(rule, for: .conversation(id))
            }
        )
    }

    var accountSettingsState: AccountSettingsState {
        guard case let .running(model) = phase else { return AccountSettingsState(signedInAs: nil) }
        return AccountSettingsState(signedInAs: Display.signedInLabel(
            me: model.me,
            directory: model.directory
        ))
    }
}
