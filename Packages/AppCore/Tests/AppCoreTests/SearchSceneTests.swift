import ChatKit
import DesignSystem
import Testing
@testable import AppCore
@testable import SyncEngine

/// The model's search, as the window sees it (search spec §1).
@MainActor
struct SearchSceneTests {
    @Test func theBarCarriesItsPositionAndMore() {
        var session = SearchSessionState()
        session.bar = SearchBarState(
            query: MessageSearchQuery(text: "x"), hits: [], next: MessageSearchCursor("1"), index: 0
        )
        let scene = AppEnvironment.searchScene(session)
        #expect(scene.bar?.hasMore == true)
        // `count` is the bar's hit count (an Int), not a collection - `isEmpty` does not apply.
        // swiftlint:disable:next empty_count
        #expect(scene.bar?.count == 0)
    }
}
