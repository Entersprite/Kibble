import AppKit
import ChatKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// The reorder model Settings › Accounts and Settings › Sidebar share: the
/// arrows and the accessibility actions agree on every end, and Favorites
/// never leaves the top of the sidebar.
struct SettingsOrderTests {
    private struct Row: Identifiable, Equatable {
        let id: String
    }

    private let rows = ["a", "b", "c"].map(Row.init)

    @Test func moveUpAndDownSwapWithTheNeighbor() {
        #expect(SettingsOrder.moving("b", .up, in: rows)?.map(\.id) == ["b", "a", "c"])
        #expect(SettingsOrder.moving("b", .down, in: rows)?.map(\.id) == ["a", "c", "b"])
    }

    @Test func nothingMovesPastAnEndOrForAnUnlistedRow() {
        #expect(SettingsOrder.moving("a", .up, in: rows) == nil)
        #expect(SettingsOrder.moving("c", .down, in: rows) == nil)
        #expect(SettingsOrder.moving("z", .up, in: rows) == nil)
        #expect(SettingsOrder.moving("a", .down, in: [Row(id: "a")]) == nil)
    }

    @Test func aRowsPlaceFollowsTheEnds() {
        let places = rows.map { SettingsOrder.place(of: $0.id, in: rows) }
        #expect(places.map(\.canMoveUp) == [false, true, true])
        #expect(places.map(\.canMoveDown) == [true, true, false])
    }

    /// The accessibility actions offer only moves that happen; the menu hides
    /// both only when there is nothing to reorder.
    @Test func actionsListOnlyPossibleMovesAndALoneRowOffersNone() {
        #expect(SettingsOrder.place(of: "a", in: rows).available == [.down])
        #expect(SettingsOrder.place(of: "c", in: rows).available == [.up])
        let alone = SettingsOrder.place(of: "a", in: [Row(id: "a")])
        #expect(alone.available.isEmpty)
        #expect(!alone.isReorderable)
        #expect(SettingsOrder.place(of: "a", in: rows).isReorderable)
    }

    @Test func titlesAreTitleCase() {
        #expect(SettingsMove.allCases.map(\.title) == ["Move Up", "Move Down"])
        #expect(SettingsMoveButtons.title(.up, name: "Spaces") == "Move Spaces Up")
        #expect(SettingsMoveButtons.title(.down, name: "Spaces") == "Move Spaces Down")
    }

    /// Every row draws its arrows, one click a move; a list of one draws none.
    @MainActor
    @Test func eachRowDrawsTwoArrowsAndALoneRowDrawsNone() {
        let middle = NSHostingView(rootView: SettingsMoveButtons(
            name: "b", place: SettingsOrder.place(of: "b", in: rows), move: { _ in }
        ))
        let alone = NSHostingView(rootView: SettingsMoveButtons(
            name: "a", place: SettingsOrder.place(of: "a", in: [Row(id: "a")]), move: { _ in }
        ))
        #expect(middle.fittingSize.width > 20)
        #expect(alone.fittingSize.width == 0)
        for direction in SettingsMove.allCases {
            #expect(NSImage(systemSymbolName: direction.systemImage, accessibilityDescription: nil) != nil)
        }
    }

    // MARK: Sidebar sections

    private let order = SidebarPreferences.identifiers

    @Test func aSidebarSectionMovesAndFavoritesStaysFirst() throws {
        let preferences = SidebarPreferences()
        let moved = try #require(SidebarSectionOrder.moving("groupDirectMessage", .up, in: preferences))
        #expect(moved.sections.first?.id == "favorites")
        #expect(moved.orderedSections.map(\.id)
            == ["groupDirectMessage", "directMessage", "space", "appDirectMessage", "meetChat"])
        #expect(moved.displaySections.first?.id == "favorites")
    }

    @Test func theFirstSectionCannotMoveAboveFavoritesNorTheLastPastTheEnd() {
        let preferences = SidebarPreferences()
        #expect(SidebarSectionOrder.moving(order[0], .up, in: preferences) == nil)
        #expect(SidebarSectionOrder.moving(order[order.count - 1], .down, in: preferences) == nil)
    }

    @Test func favoritesIsNotInTheOrderAndCannotBeMoved() {
        let preferences = SidebarPreferences()
        #expect(!preferences.orderedSections.map(\.id).contains("favorites"))
        #expect(SidebarSectionOrder.moving("favorites", .down, in: preferences) == nil)
        #expect(SidebarSectionOrder.moving("favorites", .up, in: preferences) == nil)
    }

    /// A stored order with Favorites anywhere but first comes back with it first.
    @Test func anyMovePutsFavoritesBackFirst() throws {
        var stored = SidebarPreferences()
        stored.sections = SidebarPreferences.defaults + [.init(id: "favorites", sort: .name)]
        let moved = try #require(SidebarSectionOrder.moving("space", .down, in: stored))
        #expect(moved.sections.map(\.id)
            == ["favorites", "directMessage", "groupDirectMessage", "appDirectMessage", "space", "meetChat"])
        // Its own sorting choice survives the move.
        #expect(moved.favoritesSection.sort == .name)
    }

    @Test func aMoveKeepsEachSectionsOwnSettings() throws {
        var preferences = SidebarPreferences()
        preferences.update(.init(id: "space", isVisible: false, maximumItems: 3, sort: .name))
        let moved = try #require(SidebarSectionOrder.moving("space", .up, in: preferences))
        let space = try #require(moved.orderedSections.first { $0.id == "space" })
        #expect(!space.isVisible)
        #expect(space.maximumItems == 3)
        #expect(moved.orderedSections.map(\.id).firstIndex(of: "space") == 1)
    }
}
