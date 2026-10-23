import ChatKit
import Foundation
import Testing
@testable import DesignSystem
#if os(macOS)
    import AppKit
#endif

/// Where a refused integration change is shown, and how a webhook's URL is copied.
struct IntegrationFailureTests {
    private let error = "You can’t do that here."

    /// Everything on screen: both apps and webhooks drawn.
    private let everything = IntegrationFailure.Shown(
        apps: [.init("a1")], webhooks: ["w1"], appsSection: true
    )

    private func place(
        _ sent: ConversationMutation?, pending: ConversationMutation? = nil, error: String?,
        shown: IntegrationFailure.Shown? = nil
    ) -> IntegrationFailure? {
        IntegrationFailure.place(sent: sent, pending: pending, error: error, shown: shown ?? everything)
    }

    @Test func aRefusalLandsBesideWhatFailed() {
        #expect(place(.removeApp(.init("a1")), error: error) == .app(.init("a1")))
        #expect(place(.deleteWebhook("w1"), error: error) == .webhook("w1"))
        #expect(place(.addApp(.init("a2")), error: error) == .addingApp)
    }

    @Test func nothingLandsWhileOnItsWayWithoutAnErrorOrForOtherChanges() {
        let remove = ConversationMutation.removeApp(.init("a1"))
        #expect(place(remove, pending: remove, error: error) == nil)
        #expect(place(remove, error: nil) == nil)
        #expect(place(nil, error: error) == nil)
        // The webhook editor shows its own refusal.
        #expect(place(.saveWebhook(id: "w1", name: "CI", avatarURL: ""), error: error) == nil)
    }

    /// A row that's gone (removed, or not drawn), or an Apps section that
    /// isn't drawn, can't hold the error: it stays in the sheet's header.
    @Test func nothingLandsWhereNothingIsDrawn() {
        #expect(place(.removeApp(.init("gone")), error: error) == nil)
        #expect(place(.deleteWebhook("gone"), error: error) == nil)
        let unloaded = IntegrationFailure.Shown(nil, showsApps: true, showsWebhooks: true)
        #expect(place(.addApp(.init("a2")), error: error, shown: unloaded) == nil)
        #expect(place(.removeApp(.init("a1")), error: error, shown: unloaded) == nil)
        let webhooksOnly = IntegrationFailure.Shown(
            ConversationIntegrations(
                webhooks: [ConversationWebhook(id: "w1", name: "CI")],
                apps: [ConversationApp(member: Member(id: .init("a1"), kind: .app))]
            ),
            showsApps: false, showsWebhooks: true
        )
        #expect(place(.addApp(.init("a2")), error: error, shown: webhooksOnly) == nil)
        #expect(place(.removeApp(.init("a1")), error: error, shown: webhooksOnly) == nil)
        #expect(place(.deleteWebhook("w1"), error: error, shown: webhooksOnly) == .webhook("w1"))
    }

    /// A change that went through, or whose error a reload cleared, is
    /// forgotten; one on its way or refused is kept.
    @Test func aSettledChangeIsForgotten() {
        #expect(IntegrationFailure.forgetsSent(pending: nil, error: nil))
        #expect(!IntegrationFailure.forgetsSent(pending: .deleteWebhook("w1"), error: nil))
        #expect(!IntegrationFailure.forgetsSent(pending: nil, error: error))
    }

    #if os(macOS)
        /// A webhook URL is a credential: marked concealed for clipboard
        /// managers. Ordinary copies stay plain text.
        @Test func concealedCopiesCarryTheMarker() throws {
            let pasteboard = NSPasteboard(name: .init("kibble-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            #expect(TextPasteboard.copy("https://example.test/hook", concealed: true, to: pasteboard))
            #expect(pasteboard.string(forType: .string) == "https://example.test/hook")
            let types = try #require(pasteboard.types)
            #expect(types.contains(TextPasteboard.concealedType))

            #expect(TextPasteboard.copy("someone@example.test", concealed: false, to: pasteboard))
            #expect(pasteboard.string(forType: .string) == "someone@example.test")
            #expect(pasteboard.types?.contains(TextPasteboard.concealedType) == false)
        }
    #endif
}
