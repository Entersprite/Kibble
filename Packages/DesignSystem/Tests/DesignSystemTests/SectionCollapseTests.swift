import ChatKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// Where a sidebar section's disclosure lives: with the host, which keeps it
/// across launches, or in the view, for a host that keeps none. These read
/// the binding the sidebar hands each `Section`.
@MainActor
struct SectionCollapseTests {
    private final class Calls {
        var log: [String] = []
    }

    /// The view's own set, as `@State` would hold it.
    private final class Local {
        var shut: Set<String>

        init(_ shut: Set<String> = []) {
            self.shut = shut
        }

        var binding: Binding<Set<String>> {
            Binding(get: { self.shut }, set: { self.shut = $0 })
        }
    }

    @Test func theHostsSetDecidesWhereTheHostKeepsOne() {
        let state = ChatSceneState(collapsedSections: ["space"])
        let actions = ChatSceneActions(setSectionCollapsed: { _, _ in })
        let local = Local(["meetChat"])
        #expect(!SectionCollapse.expansion(of: "space", state: state, actions: actions, local: local.binding)
            .wrappedValue)
        #expect(SectionCollapse.expansion(
            of: "meetChat",
            state: state,
            actions: actions,
            local: local.binding
        )
        .wrappedValue)
    }

    @Test func theViewsOwnSetDecidesWhereTheHostKeepsNone() {
        let state = ChatSceneState(collapsedSections: ["space"])
        let local = Local(["meetChat"])
        let actions = ChatSceneActions()
        #expect(SectionCollapse.expansion(of: "space", state: state, actions: actions, local: local.binding)
            .wrappedValue)
        #expect(!SectionCollapse.expansion(
            of: "meetChat",
            state: state,
            actions: actions,
            local: local.binding
        )
        .wrappedValue)
    }

    @Test func aToggleGoesToTheHostAndLeavesTheViewsSetAlone() {
        let calls = Calls()
        let actions = ChatSceneActions(setSectionCollapsed: { calls.log.append("\($0) \($1)") })
        let local = Local()
        let expanded = SectionCollapse.expansion(
            of: "space", state: ChatSceneState(), actions: actions, local: local.binding
        )
        expanded.wrappedValue = false
        expanded.wrappedValue = true
        #expect(calls.log == ["space true", "space false"])
        #expect(local.shut.isEmpty)
    }

    @Test func aToggleStaysInTheViewWhereTheHostKeepsNone() {
        let local = Local()
        let expanded = SectionCollapse.expansion(
            of: "space", state: ChatSceneState(), actions: ChatSceneActions(), local: local.binding
        )
        expanded.wrappedValue = false
        #expect(local.shut == ["space"])
        #expect(!expanded.wrappedValue)
        expanded.wrappedValue = true
        #expect(local.shut.isEmpty)
        #expect(expanded.wrappedValue)
    }
}
