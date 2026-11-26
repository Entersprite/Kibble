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

    /// The arrow buttons' glyphs (`SettingsMoveButtons`).
    var systemImage: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        }
    }
}

/// The one way Settings › Accounts and Settings › Sidebar change an order:
/// an up and a down arrow on every row, one click a place, and the same two
/// as named accessibility actions, so both can never disagree about the
/// ends. A drag inside a grouped `Form` did not move rows, and a menu put
/// another click before every move (owner's check).
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

    /// A row's place in the list, for its arrows and its accessibility actions.
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

    /// Whether the row draws its arrows at all; at an end, the one that
    /// cannot apply is drawn disabled.
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

/// A row's up and down arrows, borderless and icon-only, as Settings › Sidebar
/// has always drawn them. `name` says what moves, for the help tag's
/// neighbor, VoiceOver ("Move Spaces Up").
struct SettingsMoveButtons: View {
    let name: String
    let place: SettingsRowPlace
    let move: (SettingsMove) -> Void

    var body: some View {
        if place.isReorderable {
            HStack(spacing: 6) {
                ForEach(SettingsMove.allCases, id: \.self) { direction in
                    Button { move(direction) } label: {
                        Label(Self.title(direction, name: name), systemImage: direction.systemImage)
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!place.allows(direction))
                    .help(direction.title)
                }
            }
        }
    }

    static func title(_ direction: SettingsMove, name: String) -> String {
        switch direction {
        case .up: "Move \(name) Up"
        case .down: "Move \(name) Down"
        }
    }
}

extension View {
    /// The row's possible moves as named accessibility actions, so VoiceOver
    /// can reorder from the row itself. Metadata only: nothing is announced.
    func settingsMoveActions(_ place: SettingsRowPlace, move: @escaping (SettingsMove) -> Void) -> some View {
        accessibilityActions {
            ForEach(place.available, id: \.self) { direction in
                Button(direction.title) { move(direction) }
            }
        }
    }
}
