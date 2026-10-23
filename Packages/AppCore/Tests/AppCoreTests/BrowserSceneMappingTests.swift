import ChatKit
import DesignSystem
import Testing
@testable import AppCore
@testable import SyncEngine

/// The browser's conversation-info reads, as the window sees them.
@MainActor
struct BrowserSceneMappingTests {
    @Test func browserSceneCopiesEveryInfoField() throws {
        let backend = FakeLaunchBackend()
        let browser = try ConversationBrowser(
            engine: SyncEngine(backend: backend, store: ChatStore.inMemory())
        )
        let app = ConversationApp(member: Member(id: Member.ID("users/app"), kind: .app))
        let integrations = ConversationIntegrations(canCreateWebhook: true, apps: [app], canAddApps: true)
        let email = ConversationEmail(address: "a@b.c", deliveryEnabled: true, canGenerate: true)
        let conversion = ConversionConsequences(requiresHistoryAcknowledgement: false)
        browser.integrations = integrations
        browser.isLoadingIntegrations = true
        browser.integrationsError = "integrations"
        browser.appResults = [app]
        browser.isSearchingApps = true
        browser.email = email
        browser.isLoadingEmail = true
        browser.emailError = "email"
        browser.conversion = conversion
        browser.isLoadingConversion = true
        browser.conversionError = "conversion"
        browser.isLoadingAllParticipants = true

        let scene = AppEnvironment.browserScene(browser)
        #expect(scene.integrations == integrations)
        #expect(scene.isLoadingIntegrations)
        #expect(scene.integrationsError == "integrations")
        #expect(scene.appResults == [app])
        #expect(scene.isSearchingApps)
        #expect(scene.email == email)
        #expect(scene.isLoadingEmail)
        #expect(scene.emailError == "email")
        #expect(scene.conversion == conversion)
        #expect(scene.isLoadingConversion)
        #expect(scene.conversionError == "conversion")
        #expect(scene.isLoadingAllParticipants)
        #expect(scene.pendingMutation == browser.pendingMutation)
    }
}
