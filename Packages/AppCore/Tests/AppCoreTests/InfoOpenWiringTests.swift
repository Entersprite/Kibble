import ChatKit
import DesignSystem
import Testing
@testable import AppCore
@testable import SyncEngine

/// Info opened from the window gets the directory's way of showing a
/// conversation it opens: the window's details action wires selection.
@MainActor
struct InfoOpenWiringTests {
    @Test func detailsOpenedFromTheWindowSelectWhatTheyOpen() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        let model = try #require(environment.runningModel)
        let actions = try #require(environment.browserActions)
        #expect(model.browser.onOpen == nil)
        actions.details(Conversation.ID("space"), false)
        let opened = Conversation.ID("dm-from-info")
        model.browser.onOpen?(opened)
        #expect(model.selected == opened)
        await environment.signOut()
    }
}
