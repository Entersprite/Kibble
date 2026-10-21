import ChatKit
import SwiftUI

/// Local navigation choices, available independently of provider capabilities.
enum FavoriteMenu {
    static func contains(_ target: SidebarSelection, in preferences: SidebarPreferences) -> Bool {
        switch target {
        case let .conversation(id): preferences.favoriteConversations.contains(id)
        case let .meetingSeries(id): preferences.favoriteMeetings.contains(id)
        default: false
        }
    }

    static func toggling(
        _ target: SidebarSelection,
        in preferences: SidebarPreferences
    ) -> SidebarPreferences {
        var next = preferences
        let remove = contains(target, in: preferences)
        switch target {
        case let .conversation(id):
            if remove {
                next.favoriteConversations.remove(id)
            } else {
                next.favoriteConversations.insert(id)
            }
        case let .meetingSeries(id):
            if remove {
                next.favoriteMeetings.remove(id)
            } else {
                next.favoriteMeetings.insert(id)
            }
        default: break
        }
        return next
    }

    /// The item's words and symbol: a star to add, a struck-out star to
    /// remove. Checked to exist by `SidebarSymbolTests`.
    static func item(
        for target: SidebarSelection, in preferences: SidebarPreferences
    ) -> (title: String, symbol: String) {
        if contains(target, in: preferences) {
            return ("Remove from Favorites", "star.slash")
        }
        return ("Add to Favorites", "star")
    }

    static let symbols = ["star", "star.slash"]
}

struct FavoriteMenuButton: View {
    let target: SidebarSelection
    let preferences: SidebarPreferences
    let update: (SidebarPreferences) -> Void

    var body: some View {
        let item = FavoriteMenu.item(for: target, in: preferences)
        Button(item.title, systemImage: item.symbol) {
            update(FavoriteMenu.toggling(target, in: preferences))
        }
    }
}
