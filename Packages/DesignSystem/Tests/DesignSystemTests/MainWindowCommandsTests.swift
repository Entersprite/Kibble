import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// What the main window publishes for the menu bar: equal, so the menu bar is
/// not rebuilt, exactly while it comes from the same source with the same
/// menu, and Next and Previous Result under the session model's own rule.
@MainActor
struct MainWindowCommandsTests {
    private let space = Conversation(id: .init("space"), kind: .space, title: "Deploys")

    private func scene(account: String? = "a", typing: [Member.ID] = []) -> ChatSceneState {
        var state = ChatSceneState(conversations: [space], selected: space.id, typing: typing)
        state.accountID = account
        return state
    }

    @Test func aRenderThatChangesNothingTheMenuShowsIsTheSameValue() {
        let recorder = MenuActionRecorder()
        let source = NSObject()
        // Each read of `recorder.actions` makes new closures, as each render does.
        let first = MainWindowCommands(
            scope: ObjectIdentifier(source),
            state: scene(),
            actions: recorder.actions
        )
        let typing = MainWindowCommands(
            scope: ObjectIdentifier(source), state: scene(typing: [Member.ID("ann")]),
            actions: recorder.actions
        )
        #expect(first == typing)
    }

    @Test func anotherAccountOrAnotherSessionIsNeverTheSameValue() {
        let recorder = MenuActionRecorder()
        let source = NSObject(), replacement = NSObject()
        let first = MainWindowCommands(
            scope: ObjectIdentifier(source),
            state: scene(),
            actions: recorder.actions
        )
        let otherAccount = MainWindowCommands(
            scope: ObjectIdentifier(source), state: scene(account: "b"), actions: recorder.actions
        )
        let newSession = MainWindowCommands(
            scope: ObjectIdentifier(replacement), state: scene(), actions: recorder.actions
        )
        #expect(first != otherAccount)
        #expect(first != newSession)
        #expect(first.conversation.account == "a")
    }

    @Test func aChangeTheMenuShowsIsANewValue() {
        let recorder = MenuActionRecorder()
        let source = NSObject()
        let first = MainWindowCommands(
            scope: ObjectIdentifier(source),
            state: scene(),
            actions: recorder.actions
        )
        var muted = scene()
        muted.muted = [space.id]
        let changed = MainWindowCommands(
            scope: ObjectIdentifier(source),
            state: muted,
            actions: recorder.actions
        )
        #expect(first != changed)
    }

    @Test func resultsStepWhileTheBarIsUpAndTheOverlayIsNot() {
        let recorder = MenuActionRecorder()
        let bar = SearchBarScene(query: MessageSearchQuery(), index: 0, count: 3)
        func canStep(bar: SearchBarScene?, shown: Bool, search: Bool = true) -> Bool {
            var state = scene()
            state.search = SearchSceneState(isShown: shown, bar: bar)
            var actions = recorder.actions
            if !search {
                actions.search = nil
            }
            return MainWindowCommands(scope: 0, state: state, actions: actions).canStepSearch
        }
        #expect(canStep(bar: bar, shown: false))
        #expect(!canStep(bar: bar, shown: true))
        #expect(!canStep(bar: nil, shown: false))
        #expect(!canStep(bar: bar, shown: false, search: false))
    }
}
