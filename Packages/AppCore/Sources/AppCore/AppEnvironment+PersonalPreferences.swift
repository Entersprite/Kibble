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
            sidebarPreferences = .init()
            collapsedSections = []
            return
        }

        let key = Self.accountPreferencesPrefix + preferenceNamespace + account.rawValue
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
        sidebarPreferences = (saved["sidebar"] as? Data).flatMap {
            try? JSONDecoder().decode(SidebarPreferences.self, from: $0)
        } ?? .init()
    }

    func savePersonalPreferences() {
        guard let account = settings.account else { return }
        let key = Self.accountPreferencesPrefix + preferenceNamespace + account.rawValue
        var saved = preferences.dictionary(forKey: key) ?? [:]
        saved[Self.toneField] = skinTone.rawValue
        saved[Self.sectionsField] = collapsedSections.sorted()
        saved["sidebar"] = try? JSONEncoder().encode(sidebarPreferences)
        preferences.set(saved, forKey: key)
    }
}
