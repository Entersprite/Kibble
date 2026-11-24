import ChatKit
import DesignSystem
import Foundation

/// The sidebar's collapsed sections belong to the identified account.
extension AppEnvironment {
    static let collapsedSectionsKey = "sidebarCollapsedSections"

    func installConversationSectionActions(in actions: inout ChatSceneActions) {
        guard let model = runningModel, model.connectionState == .connected else { return }
        if model.capabilities.canEditConversationSections {
            actions.editConversationSection = { [weak self, weak model] edit in
                guard let self, let model, runningModel === model else { throw CancellationError() }
                try await model.updateConversationSection(edit)
            }
        }
        if model.capabilities.canMoveConversationSections {
            actions.moveConversationToSection = { [weak self, weak model] placement in
                guard let self, let model, runningModel === model else { return }
                model.moveSidebarConversation(placement)
            }
        }
        guard model.capabilities.canManageConversationSections else { return }
        actions.createConversationSection = { [weak self, weak model] name in
            guard let self, let model, runningModel === model else { throw CancellationError() }
            try await model.createConversationSection(named: name)
        }
        actions.deleteConversationSection = { [weak self, weak model] id in
            guard let self, let model, runningModel === model else { throw CancellationError() }
            try await model.deleteConversationSection(id)
        }
    }

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
        saveSidebarOverrides(before: sidebarPreferences, after: value)
        sidebarPreferences = value
        sidebarPreferences.sections = value.displaySections
        savePersonalPreferences()
    }
}
