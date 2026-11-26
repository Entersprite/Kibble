import Foundation

/// The arrow keys over the emoji picker's grid, pure so each move is a test.
///
/// The search field keeps the keyboard focus, as a menu's or Spotlight's
/// field does, and the arrows move one highlight through the grid: the
/// picker shows the keyboard's place with a highlight, never a focus ring,
/// like the account panel (`AccountPanelKeyboard`). Each section lays its
/// items out in rows of `columns`, under its own header.
struct EmojiPickerNavigation {
    enum Direction: Equatable {
        case up, down, left, right
    }

    /// Item ids, section by section, in drawing order.
    let sections: [[String]]
    let columns: Int

    init(sections: [[String]], columns: Int = EmojiPickerGrid.columns) {
        self.sections = sections.filter { !$0.isEmpty }
        self.columns = max(1, columns)
    }

    /// Down or Right from nothing starts at the first item; Up from the top
    /// row gives the arrows back to the search field (`nil`). Left and Right
    /// walk the items in order, across sections; Up and Down keep the column
    /// where the next row has one, and take the row's last item where it
    /// is shorter. The ends stay where they are.
    func move(from current: String?, _ direction: Direction) -> String? {
        guard let current, let place = place(of: current) else {
            return direction == .down || direction == .right ? sections.first?.first : nil
        }
        switch direction {
        case .left, .right:
            let flat = sections.flatMap(\.self)
            guard let index = flat.firstIndex(of: current) else { return current }
            let next = direction == .right ? index + 1 : index - 1
            return flat.indices.contains(next) ? flat[next] : current
        case .down:
            let rows = rowCount(place.section)
            if place.row + 1 < rows {
                return item(section: place.section, row: place.row + 1, column: place.column)
            }
            guard place.section + 1 < sections.count else { return current }
            return item(section: place.section + 1, row: 0, column: place.column)
        case .up:
            if place.row > 0 {
                return item(section: place.section, row: place.row - 1, column: place.column)
            }
            guard place.section > 0 else { return nil }
            let previous = place.section - 1
            return item(section: previous, row: rowCount(previous) - 1, column: place.column)
        }
    }

    /// Where an item sits: its section, and its row and column there.
    private struct Place {
        let section: Int
        let row: Int
        let column: Int
    }

    private func place(of id: String) -> Place? {
        for (section, items) in sections.enumerated() {
            if let index = items.firstIndex(of: id) {
                return Place(section: section, row: index / columns, column: index % columns)
            }
        }
        return nil
    }

    private func rowCount(_ section: Int) -> Int {
        (sections[section].count + columns - 1) / columns
    }

    private func item(section: Int, row: Int, column: Int) -> String {
        let items = sections[section]
        return items[min(row * columns + column, items.count - 1)]
    }
}

/// The picker's category jump bar: an SF Symbol for each section, by its
/// title, the way the Character Viewer marks its groups. A section with no
/// symbol here (a future category) gets the generic grid.
enum EmojiCategorySymbols {
    static let fallback = "square.grid.2x2"

    static let byTitle: [String: String] = [
        "Recent": "clock",
        "Smileys & Emotion": "face.smiling",
        "People & Body": "hand.wave",
        "Animals & Nature": "pawprint",
        "Food & Drink": "fork.knife",
        "Travel & Places": "car",
        "Activities": "soccerball",
        "Objects": "lightbulb",
        "Symbols": "heart",
        "Flags": "flag",
        "Custom": "star"
    ]

    static func symbol(for title: String) -> String {
        byTitle[title] ?? fallback
    }
}
