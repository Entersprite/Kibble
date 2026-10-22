import ChatKit
import DesignSystem
import Foundation

extension AppEnvironment {
    private nonisolated static let accountPreferencesPrefix = "personalPreferences.v1."
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
        if services.arguments.backend == .local, preferenceNamespace.isEmpty,
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
        } ?? Self.globalSidebar(in: preferences)
        if let bytes = saved["sidebarOverrides"] as? Data,
           let overrides = try? JSONDecoder().decode(SidebarOverrides.self, from: bytes),
           let resolved = try? overrides.apply(to: Self.globalSidebar(in: preferences)) {
            sidebarPreferences.sections = resolved.sections
        }
    }

    /// Forgets the local choices kept for `identity` under `namespace`, for an
    /// account removed with its settings.
    public nonisolated static func forgetPersonalPreferences(
        namespace: String, identity: Member.ID, in preferences: UserDefaults
    ) {
        preferences.removeObject(forKey: accountPreferencesPrefix + namespace + identity.rawValue)
    }

    func savePersonalPreferences() {
        guard let account = settings.account else { return }
        let key = Self.accountPreferencesPrefix + preferenceNamespace + account.rawValue
        var saved = preferences.dictionary(forKey: key) ?? [:]
        saved[Self.toneField] = skinTone.rawValue
        saved[Self.sectionsField] = collapsedSections.sorted()
        preferences.set(saved, forKey: key)
    }
}

public extension AppEnvironment {
    static func globalSidebar(in preferences: UserDefaults) -> SidebarPreferences {
        (preferences.data(forKey: "sidebarDefaults.v1")).flatMap {
            try? JSONDecoder().decode(SidebarPreferences.self, from: $0)
        } ?? .init()
    }

    static func setGlobalSidebar(_ value: SidebarPreferences?, in preferences: UserDefaults) {
        if var value {
            value.favoriteConversations = []
            value.favoriteMeetings = []
            preferences.set(try? JSONEncoder().encode(value), forKey: "sidebarDefaults.v1")
        } else {
            preferences.removeObject(forKey: "sidebarDefaults.v1")
        }
    }

    func refreshPersonalPreferences() {
        let identity = settings.account
        guard let identity else { return }
        // switchAccount's identity guard also owns notification policy loading.
        // Reload only local sidebar values here.
        let key = Self.accountPreferencesPrefix + preferenceNamespace + identity.rawValue
        let saved = preferences.dictionary(forKey: key) ?? [:]
        if let data = saved["sidebarOverrides"] as? Data,
           let overrides = try? JSONDecoder().decode(SidebarOverrides.self, from: data),
           let resolved = try? overrides.apply(to: Self.globalSidebar(in: preferences)) {
            sidebarPreferences.sections = resolved.sections
        } else if saved["sidebar"] == nil {
            sidebarPreferences.sections = Self.globalSidebar(in: preferences).sections
        }
    }

    func resetSidebar() {
        guard let identity = settings.account else { return }
        let key = Self.accountPreferencesPrefix + preferenceNamespace + identity.rawValue
        var saved = preferences.dictionary(forKey: key) ?? [:]
        saved.removeValue(forKey: "sidebar")
        saved.removeValue(forKey: "sidebarOverrides")
        saved.removeValue(forKey: Self.sectionsField)
        preferences.set(saved, forKey: key)
        sidebarPreferences = Self.globalSidebar(in: preferences)
        collapsedSections = []
    }

    func saveSidebarOverrides(before: SidebarPreferences, after: SidebarPreferences) {
        guard let identity = settings.account else { return }
        let key = Self.accountPreferencesPrefix + preferenceNamespace + identity.rawValue
        var saved = preferences.dictionary(forKey: key) ?? [:]
        var overrides: SidebarOverrides
        if let data = saved["sidebarOverrides"] as? Data,
           let kept = try? JSONDecoder().decode(SidebarOverrides.self, from: data) {
            overrides = kept
        } else {
            overrides = SidebarOverrides()
            // Existing full documents are explicit choices. Preserve them on upgrade.
            if saved["sidebar"] != nil {
                try? overrides.record(before: .init(), after: before)
            }
        }
        try? overrides.record(before: before, after: after)
        saved["sidebarOverrides"] = try? JSONEncoder().encode(overrides)
        saved["sidebar"] = try? JSONEncoder().encode(after)
        preferences.set(saved, forKey: key)
    }
}
