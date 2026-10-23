import ChatKit
import SwiftUI

/// Where the window is: a sidebar place with the thread open beside it, or a
/// directory page, which covers whatever the sidebar has chosen underneath.
enum NavigationPlace: Hashable {
    case sidebar(SidebarSelection, thread: MessageThread.ID?)
    case page(String)
}

/// One account's Back and Forward, as a browser keeps them: a visit drops
/// everything ahead of the current place, and stepping moves along the list
/// without changing it. A plain value, so tests reach it without a window.
struct NavigationHistory: Equatable {
    /// How many places Back can reach, the current one included.
    static let limit = 100

    private(set) var places: [NavigationPlace] = []
    private(set) var index = -1

    var current: NavigationPlace? {
        places.indices.contains(index) ? places[index] : nil
    }

    var canGoBack: Bool {
        index > 0
    }

    var canGoForward: Bool {
        index < places.count - 1
    }

    /// Records where the window went. Arriving at the current place, which is
    /// what a step itself does, records nothing.
    mutating func visit(_ place: NavigationPlace) {
        guard place != current else { return }
        places.removeSubrange((index + 1)...)
        places.append(place)
        if places.count > Self.limit {
            places.removeFirst(places.count - Self.limit)
        }
        index = places.count - 1
    }

    /// Moves one place back, passing over and forgetting places that can no
    /// longer be shown (a conversation left since), and returns where to go.
    mutating func back(where available: (NavigationPlace) -> Bool) -> NavigationPlace? {
        while index > 0 {
            if available(places[index - 1]) {
                index -= 1
                return places[index]
            }
            places.remove(at: index - 1)
            index -= 1
        }
        return nil
    }

    /// Moves one place forward, as `back(where:)` does the other way.
    mutating func forward(where available: (NavigationPlace) -> Bool) -> NavigationPlace? {
        while index < places.count - 1 {
            if available(places[index + 1]) {
                index += 1
                return places[index]
            }
            places.remove(at: index + 1)
        }
        return nil
    }
}

/// Back and Forward for the menu bar, published by the main window.
///
/// Equal while the window's account and what can be stepped to stay the
/// same, so the menu bar is not rebuilt on every render. `step` reaches the
/// window's latest render (`NavigationStepper`), never the one that
/// published it.
struct NavigationHistoryCommands: Equatable {
    let scope: String?
    let canGoBack: Bool
    let canGoForward: Bool
    let step: @MainActor (NavigationStep) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.canGoBack == rhs.canGoBack && lhs.canGoForward == rhs.canGoForward
    }
}

enum NavigationStep {
    case back
    case forward
}

/// Holds the latest render's step, so a menu command published by an earlier,
/// equal render still acts on today's state. A class, so updating it draws
/// nothing.
@MainActor
final class NavigationStepper {
    var step: (NavigationStep) -> Void = { _ in }
}

extension FocusedValues {
    @Entry var navigationHistory: NavigationHistoryCommands?
}

/// View › Back and Forward. One Back serves both windows that step back: the
/// Notifications settings pane in front takes it for its pages, and the main
/// window for its history. Two items claiming ⌘[ would leave the second
/// without its key (`MenuBarShortcuts`).
public struct NavigationCommands: Commands {
    @FocusedValue(\.notificationSettingsBack) private var settingsBack
    @FocusedValue(\.navigationHistory) private var history

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Back", systemImage: "chevron.left") {
                if let settingsBack {
                    settingsBack.perform()
                } else {
                    history?.step(.back)
                }
            }
            .keyboardShortcut(MenuBarShortcuts.back)
            .disabled(settingsBack == nil && history?.canGoBack != true)
            Button("Forward", systemImage: "chevron.right") { history?.step(.forward) }
                .keyboardShortcut(MenuBarShortcuts.forward)
                .disabled(settingsBack != nil || history?.canGoForward != true)
        }
    }
}

/// Back and Forward at the sidebar's top, in one capsule as neighbors with no
/// spacer between them. Always drawn, so the + beside them never moves; each
/// is disabled while there is nowhere to step. The shortcuts are the menu
/// bar's (`NavigationCommands`): a toolbar button's would be a second claim.
struct NavigationTools: ToolbarContent {
    let canGoBack: Bool
    let canGoForward: Bool
    let step: (NavigationStep) -> Void

    var body: some ToolbarContent {
        ToolbarItem(id: "sidebar.back", placement: .primaryAction) {
            Button("Back", systemImage: "chevron.left") { step(.back) }
                .disabled(!canGoBack)
                .help("Back (⌘[)")
        }
        ToolbarItem(id: "sidebar.forward", placement: .primaryAction) {
            Button("Forward", systemImage: "chevron.right") { step(.forward) }
                .disabled(!canGoForward)
                .help("Forward (⌘])")
        }
    }
}
