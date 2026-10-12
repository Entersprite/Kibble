import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// The sidebar's collapsed sections are the app's, kept in its defaults like
/// the skin tone, so they survive a relaunch and a sign-out.
@MainActor
struct SidebarCollapseWiringTests {
    @Test func aCollapsedSectionIsSavedAndReadBack() async throws {
        let suite = "sidebar-collapse-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try FakeLaunchServices()
        let first = AppEnvironment(services: services, preferences: defaults)
        await first.start()
        let collapse = try #require(first.actions.setSectionCollapsed)
        collapse("space", true)
        #expect(first.sceneState.collapsedSections == ["space"])
        let second = AppEnvironment(services: services, preferences: defaults)
        await second.start()
        #expect(second.sceneState.collapsedSections == ["space"])
    }

    @Test func anExpandedSectionIsForgotten() async throws {
        let suite = "sidebar-collapse-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try FakeLaunchServices()
        let first = AppEnvironment(services: services, preferences: defaults)
        await first.start()
        let collapse = try #require(first.actions.setSectionCollapsed)
        collapse("space", true)
        collapse("directMessage", true)
        collapse("space", false)
        #expect(first.sceneState.collapsedSections == ["directMessage"])
        let second = AppEnvironment(services: services, preferences: defaults)
        await second.start()
        #expect(second.sceneState.collapsedSections == ["directMessage"])
    }
}
