import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Where a sidebar section's disclosure lives: with the host, which keeps it
/// across launches, or in the view, for a host that keeps none.
@MainActor
struct SectionCollapseTests {
    private final class Calls {
        var log: [String] = []
    }

    @Test func theHostsSetDecidesWhereTheHostKeepsOne() {
        let state = ChatSceneState(collapsedSections: ["space"])
        let actions = ChatSceneActions(setSectionCollapsed: { _, _ in })
        #expect(SectionCollapse.collapsed(state: state, actions: actions, local: ["meetChat"]) == ["space"])
    }

    @Test func theViewsOwnSetDecidesWhereTheHostKeepsNone() {
        let state = ChatSceneState(collapsedSections: ["space"])
        #expect(
            SectionCollapse.collapsed(state: state, actions: ChatSceneActions(), local: ["meetChat"])
                == ["meetChat"]
        )
    }

    @Test func aToggleGoesToTheHostAndLeavesTheViewsSetAlone() {
        let calls = Calls()
        let actions = ChatSceneActions(setSectionCollapsed: { calls.log.append("\($0) \($1)") })
        var local: Set<String> = []
        SectionCollapse.set("space", collapsed: true, actions: actions, local: &local)
        SectionCollapse.set("space", collapsed: false, actions: actions, local: &local)
        #expect(calls.log == ["space true", "space false"])
        #expect(local.isEmpty)
    }

    @Test func aToggleStaysInTheViewWhereTheHostKeepsNone() {
        var local: Set<String> = []
        SectionCollapse.set("space", collapsed: true, actions: ChatSceneActions(), local: &local)
        #expect(local == ["space"])
        SectionCollapse.set("space", collapsed: false, actions: ChatSceneActions(), local: &local)
        #expect(local.isEmpty)
    }
}
