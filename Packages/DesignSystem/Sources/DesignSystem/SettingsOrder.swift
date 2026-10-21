import SwiftUI

/// Which way a row moves in an order the person sets in Settings.
enum SettingsMove: CaseIterable, Hashable, Sendable {
    case up
    case down

    var title: String {
        switch self {
        case .up: "Move Up"
        case .down: "Move Down"
        }
    }

    var systemImage: String {
        switch self {
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }
}

/// The one way Settings › Accounts and Settings › Sidebar change an order.
/// A drag (`onMove`), Move Up and Move Down in a row's menu, and the same two
/// as named accessibility actions all produce the new order here, so the
/// three can never disagree about the ends. A drag alone left no way to
/// reorder from the keyboard, and arrow buttons on every row were clutter.
enum SettingsOrder {
    /// `items` with the one identified by `id` one place earlier or later;
    /// `nil` when it is already at that end, or not listed at all.
    static func moving<Item: Identifiable>(_ id: Item.ID, _ move: SettingsMove, in items: [Item]) -> [Item]? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let target = move == .up ? index - 1 : index + 1
        guard items.indices.contains(target) else { return nil }
        var moved = items
        moved.swapAt(index, target)
        return moved
    }

    /// A drag's result, as `onMove` reports it.
    static func moving<Item>(
        _ items: [Item],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [Item] {
        var moved = items
        moved.move(fromOffsets: source, toOffset: destination)
        return moved
    }

    /// A row's place in the list, for its menu and its accessibility actions.
    static func place<Item: Identifiable>(of id: Item.ID, in items: [Item]) -> SettingsRowPlace {
        SettingsRowPlace(
            canMoveUp: moving(id, .up, in: items) != nil,
            canMoveDown: moving(id, .down, in: items) != nil
        )
    }
}

/// Where a row can go from where it is. A list of one offers no moves at all.
struct SettingsRowPlace: Equatable, Sendable {
    var canMoveUp: Bool
    var canMoveDown: Bool

    /// Whether the row's menu offers Move Up and Move Down at all; at an end,
    /// the one that cannot apply is shown disabled, as a pull-down menu does.
    var isReorderable: Bool {
        canMoveUp || canMoveDown
    }

    func allows(_ move: SettingsMove) -> Bool {
        switch move {
        case .up: canMoveUp
        case .down: canMoveDown
        }
    }

    /// Only the moves that can happen: an accessibility action that does
    /// nothing would still be announced.
    var available: [SettingsMove] {
        SettingsMove.allCases.filter(allows)
    }
}

/// Move Up and Move Down for a row's menu and context menu.
struct SettingsMoveMenuItems: View {
    let place: SettingsRowPlace
    let move: (SettingsMove) -> Void

    var body: some View {
        if place.isReorderable {
            ForEach(SettingsMove.allCases, id: \.self) { direction in
                Button(direction.title, systemImage: direction.systemImage) { move(direction) }
                    .disabled(!place.allows(direction))
            }
        }
    }
}

extension View {
    /// The row's possible moves as named accessibility actions, so VoiceOver
    /// can reorder without a drag. Metadata only: nothing is announced.
    func settingsMoveActions(_ place: SettingsRowPlace, move: @escaping (SettingsMove) -> Void) -> some View {
        accessibilityActions {
            ForEach(place.available, id: \.self) { direction in
                Button(direction.title) { move(direction) }
            }
        }
    }
}
