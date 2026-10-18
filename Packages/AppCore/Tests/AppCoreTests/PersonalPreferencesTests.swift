import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

@MainActor
struct PersonalPreferencesTests {
    private let alice = Member(id: Member.ID("users/alice"), kind: .human)
    private let bob = Member(id: Member.ID("users/bob"), kind: .human)

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "personal-preferences-\(UUID().uuidString)"))
    }

    private func identify(
        _ member: Member,
        in environment: AppEnvironment,
        services: FakeLaunchServices
    ) async {
        services.backend.emit(.selfIdentified(member))
        #expect(await eventually { environment.settings.account == member.id })
    }

    @Test func preferencesWaitForIdentityAndStayWithTheirAccount() async throws {
        let preferences = try defaults()
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services, preferences: preferences)
        await environment.start()

        environment.setSkinTone(.dark)
        environment.setSection("space", collapsed: true)
        #expect(environment.skinTone == .none)
        #expect(environment.collapsedSections.isEmpty)

        await identify(alice, in: environment, services: services)
        environment.setSkinTone(.medium)
        environment.setSection("space", collapsed: true)
        await identify(bob, in: environment, services: services)
        #expect(environment.skinTone == .none)
        #expect(environment.collapsedSections.isEmpty)
        environment.setSkinTone(.light)
        environment.setSection("directMessage", collapsed: true)
        await identify(alice, in: environment, services: services)
        #expect(environment.skinTone == .medium)
        #expect(environment.collapsedSections == ["space"])
        await environment.signOut()
        #expect(environment.skinTone == .none)
        #expect(environment.collapsedSections.isEmpty)
    }

    @Test func legacyPreferencesMoveToFirstRealAccountOnly() async throws {
        let preferences = try defaults()
        preferences.set(SkinTone.dark.rawValue, forKey: AppEnvironment.skinToneKey)
        preferences.set(["space"], forKey: AppEnvironment.collapsedSectionsKey)

        let fixtureServices = try FakeLaunchServices(arguments: LaunchArguments(backend: .fixture))
        let fixture = AppEnvironment(services: fixtureServices, preferences: preferences)
        await fixture.start()
        await identify(alice, in: fixture, services: fixtureServices)
        #expect(fixture.skinTone == .none)
        #expect(fixture.collapsedSections.isEmpty)
        #expect(preferences.object(forKey: AppEnvironment.skinToneKey) != nil)

        let realServices = try FakeLaunchServices()
        let real = AppEnvironment(services: realServices, preferences: preferences)
        await real.start()
        await identify(bob, in: real, services: realServices)
        #expect(real.skinTone == .dark)
        #expect(real.collapsedSections == ["space"])
        #expect(preferences.object(forKey: AppEnvironment.skinToneKey) == nil)
        #expect(preferences.object(forKey: AppEnvironment.collapsedSectionsKey) == nil)

        let laterServices = try FakeLaunchServices()
        let later = AppEnvironment(services: laterServices, preferences: preferences)
        await later.start()
        await identify(alice, in: later, services: laterServices)
        #expect(later.skinTone == .none)
        #expect(later.collapsedSections.isEmpty)
    }
}

extension PersonalPreferencesTests {
    @Test func sidebarPreferencesStayWithTheirAccountAndPreserveUnrelatedFields() async throws {
        let preferences = try defaults()
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services, preferences: preferences)
        await environment.start()
        let configured = SidebarPreferences(sections: [.init(id: "space", maximumItems: 35, sort: .activity)])
        environment.updateSidebar(configured)
        #expect(environment.sidebarPreferences == SidebarPreferences())
        await identify(alice, in: environment, services: services)
        let key = "personalPreferences.v1.\(alice.id.rawValue)"
        preferences.set(["futurePreference": "preserve-me"], forKey: key)
        environment.updateSidebar(configured)
        #expect(preferences.dictionary(forKey: key)?["futurePreference"] as? String == "preserve-me")
        await identify(bob, in: environment, services: services)
        #expect(environment.sidebarPreferences == SidebarPreferences())
        await identify(alice, in: environment, services: services)
        #expect(environment.sidebarPreferences.orderedSections == configured.orderedSections)
        await environment.signOut()
        #expect(environment.sidebarPreferences == SidebarPreferences())
    }
}

extension PersonalPreferencesTests {
    @Test func favoritesSurviveRelaunchAndStayWithTheirAccount() async throws {
        let preferences = try defaults()
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services, preferences: preferences)
        await environment.start()
        let saved = SidebarPreferences(
            sections: [.init(id: "favorites", sort: .name, isAscending: false)],
            favoriteConversations: [.init("chat")], favoriteMeetings: [.init("meeting")]
        )
        environment.updateSidebar(saved)
        #expect(environment.sidebarPreferences.favoriteConversations.isEmpty)
        await identify(alice, in: environment, services: services)
        environment.actions.updateSidebar?(saved)
        await identify(bob, in: environment, services: services)
        #expect(environment.sidebarPreferences.favoriteConversations.isEmpty)
        await identify(alice, in: environment, services: services)
        #expect(environment.sidebarPreferences.favoriteConversations == saved.favoriteConversations)
        await environment.signOut()
        #expect(environment.sidebarPreferences.favoriteConversations.isEmpty)

        let nextServices = try FakeLaunchServices()
        let next = AppEnvironment(services: nextServices, preferences: preferences)
        await next.start()
        await identify(alice, in: next, services: nextServices)
        #expect(next.sidebarPreferences.favoriteConversations == saved.favoriteConversations)
        #expect(next.sidebarPreferences.favoriteMeetings == saved.favoriteMeetings)
        #expect(next.sidebarPreferences.favoritesSection.sort == .name)
        #expect(!next.sidebarPreferences.favoritesSection.sortsAscending)
        await next.signOut()
    }
}
