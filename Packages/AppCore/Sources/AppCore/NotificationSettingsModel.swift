import ChatKit
import Foundation
import Observation

/// The one writer of notification settings, for whichever account is signed in.
///
/// **Settings belong to an account** (spec §3.1). `switchAccount(to:)` loads
/// that account's records, or starts from the defaults and presets; `nil`
/// means nobody is identified, and read receipts are then withheld by whoever
/// listens to `onChange`. Sign-out switches to `nil` and deletes nothing, so
/// signing back in to the same account restores every rule.
@MainActor
@Observable
public final class NotificationSettingsModel {
    public private(set) var account: Member.ID?
    public private(set) var settings = NotificationSettings()
    /// The last load or save failure, for the settings window to mention.
    public private(set) var lastError: String?

    /// Told of every change: the settings, or `nil` when no account is identified.
    @ObservationIgnored var onChange: (@MainActor (NotificationSettings?) -> Void)?

    /// The hidden switch ghost mode used to be (`AppEnvironment` read it once,
    /// before rules existed). Migrated into the first account's global rule.
    static let legacyGhostModeKey = "ghostMode"

    @ObservationIgnored private let store: any NotificationSettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var device: String?

    public init(
        store: any NotificationSettingsStore,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.defaults = defaults
        self.now = now
    }

    public func switchAccount(to account: Member.ID?) {
        guard account != self.account else { return }
        self.account = account
        settings = NotificationSettings()
        if let account {
            do {
                settings = try store.load(for: account) ?? NotificationSettings()
                lastError = nil
            } catch {
                lastError =
                    "GChat couldn’t read your saved notification settings, so the defaults are in use."
            }
            migrateLegacyGhostMode()
        }
        onChange?(account == nil ? nil : settings)
    }

    public func rule(for scope: SettingsScope) -> NotificationRule {
        settings.rule(for: scope) ?? NotificationRule()
    }

    public func update(_ rule: NotificationRule, for scope: SettingsScope) {
        guard account != nil else { return }
        settings.setRule(rule, for: scope, at: now(), by: deviceID())
        persist()
        onChange?(settings)
    }

    /// Empties the scope's record - never deletes it (spec §2.2).
    public func reset(_ scope: SettingsScope) {
        update(NotificationRule(), for: scope)
    }

    public func resolved(for conversation: Conversation) -> ResolvedRule {
        settings.resolve(for: conversation)
    }

    private func deviceID() -> String {
        if let device {
            return device
        }
        let id = (try? store.deviceID()) ?? "unknown-device"
        device = id
        return id
    }

    private func persist() {
        guard let account else { return }
        do {
            try store.save(settings, for: account)
            lastError = nil
        } catch {
            lastError = "GChat couldn’t save your notification settings."
        }
    }

    private func migrateLegacyGhostMode() {
        guard defaults.bool(forKey: Self.legacyGhostModeKey) else { return }
        defaults.removeObject(forKey: Self.legacyGhostModeKey)
        guard settings.rule(for: .global) == nil else { return }
        settings.setRule(NotificationRule(readReceipts: false), for: .global, at: now(), by: deviceID())
        persist()
    }
}
