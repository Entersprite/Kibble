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
    /// What went wrong, for the settings window to mention - a load failure,
    /// a save failure, or both.
    ///
    /// **A load failure outlives a save that works.** It stays until the
    /// account changes: the defaults it put in use are still in use, and the
    /// first edit on a corrupt file saves successfully, so clearing it there
    /// erased the only notice. A save failure lasts until the next save works.
    public var lastError: String? {
        let errors = [loadError, saveError].compactMap(\.self)
        return errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    private var loadError: String?
    private var saveError: String?

    /// Told of every change: the settings, or `nil` when no account is identified.
    @ObservationIgnored var onChange: (@MainActor (NotificationSettings?) -> Void)?

    /// The hidden switch ghost mode used to be (`AppEnvironment` read it once,
    /// before rules existed). Migrated into the first account's global rule.
    static let legacyGhostModeKey = "ghostMode"

    @ObservationIgnored private let store: any NotificationSettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var device: String?
    /// Whether the legacy `ghostMode` key may be consumed at all. `false` for
    /// a fixture launch: `FakeBackend` identifies its own demo account, and the
    /// live check runs `--backend=fixture` first - so the key would be moved
    /// into the fixture account and deleted, and the real account would then
    /// publish receipts. Left in place, it waits for the first real account.
    @ObservationIgnored let migratesLegacyGhostMode: Bool

    public init(
        store: any NotificationSettingsStore,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        migratesLegacyGhostMode: Bool = true
    ) {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.migratesLegacyGhostMode = migratesLegacyGhostMode
    }

    public func switchAccount(to account: Member.ID?) {
        guard account != self.account else { return }
        self.account = account
        settings = NotificationSettings()
        loadError = nil
        saveError = nil
        if let account {
            do {
                settings = try store.load(for: account) ?? NotificationSettings()
            } catch {
                loadError = "GChat couldn’t read your saved notification settings. The defaults are in use, "
                    + "with read receipts off until you turn them back on."
                withholdReceiptsAfterLoadFailure()
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
            saveError = nil
        } catch {
            saveError = "GChat couldn’t save your notification settings."
        }
    }

    /// Defaults would publish read receipts, and the file that could not be
    /// read may be what turned them off - so they start off, per the spec's
    /// "assume less, never more" (the owner's decision, session 26). **Saved,
    /// not only held:** the file store has moved the unreadable file aside,
    /// so the next launch loads cleanly and would publish receipts again.
    private func withholdReceiptsAfterLoadFailure() {
        settings.setRule(NotificationRule(readReceipts: false), for: .global, at: now(), by: deviceID())
        persist()
    }

    private func migrateLegacyGhostMode() {
        guard migratesLegacyGhostMode, defaults.bool(forKey: Self.legacyGhostModeKey) else { return }
        defaults.removeObject(forKey: Self.legacyGhostModeKey)
        guard settings.rule(for: .global) == nil else { return }
        settings.setRule(NotificationRule(readReceipts: false), for: .global, at: now(), by: deviceID())
        persist()
    }
}
