import ChatKit
import Testing
@testable import DesignSystem

/// The arrows over the picker's grid (`EmojiPickerNavigation`), in a grid
/// three wide: section A has a full row and one more, B a single short row.
@MainActor
struct EmojiPickerNavigationTests {
    private let navigation = EmojiPickerNavigation(
        sections: [["a1", "a2", "a3", "a4"], [], ["b1", "b2"]], columns: 3
    )

    @Test func downOrRightFromNothingStartsAtTheFirstItem() {
        #expect(navigation.move(from: nil, .down) == "a1")
        #expect(navigation.move(from: nil, .right) == "a1")
        #expect(navigation.move(from: nil, .up) == nil)
        #expect(navigation.move(from: nil, .left) == nil)
    }

    @Test func leftAndRightWalkTheItemsAcrossSections() {
        #expect(navigation.move(from: "a3", .right) == "a4")
        #expect(navigation.move(from: "a4", .right) == "b1")
        #expect(navigation.move(from: "b1", .left) == "a4")
        #expect(navigation.move(from: "a1", .left) == "a1")
        #expect(navigation.move(from: "b2", .right) == "b2")
    }

    @Test func downKeepsTheColumnOrTakesAShorterRowsLast() {
        #expect(navigation.move(from: "a1", .down) == "a4")
        #expect(navigation.move(from: "a3", .down) == "a4")
        // The empty section is skipped; B's row has two items.
        #expect(navigation.move(from: "a4", .down) == "b1")
        #expect(navigation.move(from: "b2", .down) == "b2")
    }

    @Test func upFromTheTopRowGivesTheArrowsBackToTheField() {
        #expect(navigation.move(from: "b2", .up) == "a4")
        #expect(navigation.move(from: "a4", .up) == "a1")
        #expect(navigation.move(from: "a2", .up) == nil)
    }

    @Test func anUnknownHighlightStartsOver() {
        #expect(navigation.move(from: "gone", .down) == "a1")
    }

    /// An emoji in Recent and in its category is two cells, two ids.
    @Test func aCellIsNamedByItsSectionToo() {
        let item = EmojiPickerItem(choice: ReactionChoice(emoji: "👍"), name: "thumbs up")
        let recent = EmojiPickerSection(title: "Recent", items: [item])
        let people = EmojiPickerSection(title: "People & Body", items: [item])
        #expect(EmojiPickerGrid.cellID(recent, item) != EmojiPickerGrid.cellID(people, item))
        #expect(EmojiPickerGrid.item(EmojiPickerGrid.cellID(people, item), in: [recent, people]) == item)
        #expect(EmojiPickerGrid.item("nothing", in: [recent, people]) == nil)
    }
}
