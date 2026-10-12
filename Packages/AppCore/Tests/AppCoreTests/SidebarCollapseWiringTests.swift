import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// The sidebar's collapsed sections follow the identified account.
@MainActor
struct SidebarCollapseWiringTests {
    @Test func aCollapsedSectionIsSavedAndReadBack() async throws {
        let suite = "sidebar-collapse-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try FakeLaunchServices()
        let first = AppEnvironment(services: services, preferences: defaults)
        await first.start()
        let me = Member(id: Member.ID("users/me"), kind: .human)
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { first.settings.account == me.id })
        let collapse = try #require(first.actions.setSectionCollapsed)
        collapse("space", true)
        #expect(first.sceneState.collapsedSections == ["space"])
        let secondServices = try FakeLaunchServices()
        let second = AppEnvironment(services: secondServices, preferences: defaults)
        await second.start()
        secondServices.backend.emit(.selfIdentified(me))
        #expect(await eventually { second.settings.account == me.id })
        #expect(second.sceneState.collapsedSections == ["space"])
    }

    @Test func anExpandedSectionIsForgotten() async throws {
        let suite = "sidebar-collapse-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try FakeLaunchServices()
        let first = AppEnvironment(services: services, preferences: defaults)
        await first.start()
        let me = Member(id: Member.ID("users/me"), kind: .human)
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { first.settings.account == me.id })
        let collapse = try #require(first.actions.setSectionCollapsed)
        collapse("space", true)
        collapse("directMessage", true)
        collapse("space", false)
        #expect(first.sceneState.collapsedSections == ["directMessage"])
        let secondServices = try FakeLaunchServices()
        let second = AppEnvironment(services: secondServices, preferences: defaults)
        await second.start()
        secondServices.backend.emit(.selfIdentified(me))
        #expect(await eventually { second.settings.account == me.id })
        #expect(second.sceneState.collapsedSections == ["directMessage"])
    }
}
