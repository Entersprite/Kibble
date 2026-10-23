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

    @Test func aRefusalLandsBesideWhatFailed() {
        #expect(IntegrationFailure
            .place(sent: .removeApp(.init("a1")), pending: nil, error: error) == .app(.init("a1")))
        #expect(IntegrationFailure
            .place(sent: .deleteWebhook("w1"), pending: nil, error: error) == .webhook("w1"))
        #expect(IntegrationFailure
            .place(sent: .addApp(.init("a2")), pending: nil, error: error) == .addingApp)
    }

    @Test func nothingLandsWhileOnItsWayWithoutAnErrorOrForOtherChanges() {
        let remove = ConversationMutation.removeApp(.init("a1"))
        #expect(IntegrationFailure.place(sent: remove, pending: remove, error: error) == nil)
        #expect(IntegrationFailure.place(sent: remove, pending: nil, error: nil) == nil)
        #expect(IntegrationFailure.place(sent: nil, pending: nil, error: error) == nil)
        // The webhook editor shows its own refusal.
        let save = ConversationMutation.saveWebhook(id: "w1", name: "CI", avatarURL: "")
        #expect(IntegrationFailure.place(sent: save, pending: nil, error: error) == nil)
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
