import ChatKit
import DesignSystem
import Foundation

extension AppEnvironment {
    private static let accountPreferencesPrefix = "personalPreferences.v1."
    private static let toneField = "skinTone"
    private static let sectionsField = "collapsedSections"

    /// Load local choices when the backend identifies an account. The old
    /// app-wide values are claimed once by the first real account; the demo
    /// account cannot consume them.
    func switchAccount(to account: Member.ID?) {
        guard settings.account != account else { return }
        settings.switchAccount(to: account)
        guard let account else {
            skinTone = .none
            collapsedSections = []
            return
        }

        let key = Self.accountPreferencesPrefix + account.rawValue
        let legacyTone = preferences.object(forKey: Self.skinToneKey)
        let legacySections = preferences.stringArray(forKey: Self.collapsedSectionsKey)
        if services.arguments.backend == .local,
           legacyTone != nil || legacySections != nil {
            if preferences.object(forKey: key) == nil {
                preferences.set([
                    Self.toneField: legacyTone as? Int ?? SkinTone.none.rawValue,
                    Self.sectionsField: legacySections ?? []
                ], forKey: key)
            }
            preferences.removeObject(forKey: Self.skinToneKey)
            preferences.removeObject(forKey: Self.collapsedSectionsKey)
        }

        let saved = preferences.dictionary(forKey: key) ?? [:]
        skinTone = SkinTone(rawValue: saved[Self.toneField] as? Int ?? 0) ?? .none
        collapsedSections = Set(saved[Self.sectionsField] as? [String] ?? [])
    }

    func savePersonalPreferences() {
        guard let account = settings.account else { return }
        preferences.set([
            Self.toneField: skinTone.rawValue,
            Self.sectionsField: collapsedSections.sorted()
        ], forKey: Self.accountPreferencesPrefix + account.rawValue)
    }
}
