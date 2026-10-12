import Foundation

/// The sidebar's collapsed sections: one app-wide set in the app's defaults,
/// like the skin tone, offered to the sidebar through `ChatSceneActions`. Not
/// personal data, so it survives sign-out.
extension AppEnvironment {
    static let collapsedSectionsKey = "sidebarCollapsedSections"

    func setSection(_ id: String, collapsed: Bool) {
        if collapsed {
            collapsedSections.insert(id)
        } else {
            collapsedSections.remove(id)
        }
        preferences.set(collapsedSections.sorted(), forKey: Self.collapsedSectionsKey)
    }
}
