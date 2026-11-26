import ChatKit
import DesignSystem
import Testing
@testable import AppCore
@testable import SyncEngine

/// Edit › Find › Next Result and Previous Result read the window's scene, so
/// the scene must carry what the session model steps by: a results bar, and
/// the overlay not shown (`ChatSessionModel.canStepSearch`).
@MainActor
struct MenuBarSearchStepTests {
    @Test func theWindowsCommandsStepExactlyWhereTheModelWould() {
        let bar = SearchBarState(query: MessageSearchQuery(text: "x"), hits: [], next: nil, index: 0)
        let search = SearchActions(
            show: {}, hide: {}, textChanged: { _ in }, setQuery: { _ in }, submit: {}, loadMore: {},
            openConversation: { _ in }, openPerson: { _ in }, openMessage: { _ in }, step: { _ in }, end: {}
        )
        var actions = ChatSceneActions()
        actions.search = search
        for hasBar in [false, true] {
            for isShown in [false, true] {
                var session = SearchSessionState()
                session.bar = hasBar ? bar : nil
                session.isShown = isShown
                var state = ChatSceneState()
                state.search = AppEnvironment.searchScene(session)
                let commands = MainWindowCommands(scope: 0, state: state, actions: actions)
                #expect(commands.canStepSearch == (session.bar != nil && !session.isShown))
            }
        }
    }
}
