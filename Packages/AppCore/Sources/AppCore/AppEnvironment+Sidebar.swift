import ChatKit
import Foundation

/// The sidebar's collapsed sections belong to the identified account.
extension AppEnvironment {
    static let collapsedSectionsKey = "sidebarCollapsedSections"

    func setSection(_ id: String, collapsed: Bool) {
        guard settings.account != nil else { return }
        if collapsed {
            collapsedSections.insert(id)
        } else {
            collapsedSections.remove(id)
        }
        savePersonalPreferences()
    }
}

public extension AppEnvironment {
    func updateSidebar(_ value: SidebarPreferences) {
        guard settings.account != nil else { return }
        sidebarPreferences = SidebarPreferences(sections: value.orderedSections)
        savePersonalPreferences()
    }
}
