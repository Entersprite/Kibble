#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor @Suite(.serialized)
    struct ConversationPreviewHostedTests {
        @Test func theNativeSheetOffersJoinAndBlockWithoutInvitationButtons() async throws {
            NSApplication.shared.accessibilitySetValue(
                true,
                forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            )
            var state = ChatSceneState()
            var mutations: [ConversationMutation] = []
            let details = ConversationDetails(
                conversation: Conversation(id: .init("unjoined"), kind: .space, title: "Coffee Break"),
                membership: .invited, allowedActions: ["acceptInvitation", "block"]
            )
            state.browser.details = details
            let actions = ConversationBrowserActions(
                show: { _ in }, back: {}, search: { _, _, _ in }, reviewCreation: {},
                searchPeople: { _ in }, beginCreation: { _ in }, create: { _ in },
                closePanel: {}, details: { _, _ in }, preview: { _ in }, mutate: { mutations.append($0) }
            )
            let host = NSHostingView(rootView: Color.clear.frame(width: 640, height: 640)
                .sheet(isPresented: .constant(true)) {
                    ConversationPreviewSheet(details: details, state: state, actions: actions)
                })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            for _ in 0 ..< 100 where window.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let sheet = try #require(window.attachedSheet)
            let content = try #require(sheet.contentView)
            for _ in 0 ..< 100 where !labels(in: content).contains("Join") {
                try await Task.sleep(for: .milliseconds(10))
            }
            let controls = labels(in: content)
            #expect(controls.contains("Join"), "\(controls)")
            #expect(controls.contains("Block…"), "\(controls)")
            #expect(!controls
                .contains { $0.contains("Accept Invitation") || $0.contains("Decline Invitation") })
            let enter = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
            _ = content.performKeyEquivalent(with: enter)
            #expect(mutations == [.acceptInvitation])
        }

        private func labels(in node: NSObject) -> [String] {
            let labelSelector = NSSelectorFromString("accessibilityLabel")
            let childSelector = NSSelectorFromString("accessibilityChildren")
            let label = node.responds(to: labelSelector)
                ? node.perform(labelSelector)?.takeUnretainedValue() as? String : nil
            let children = node.responds(to: childSelector)
                ? node.perform(childSelector)?.takeUnretainedValue() as? [NSObject] : nil
            return (label.map { [$0] } ?? []) + (children ?? []).flatMap(labels(in:))
        }
    }
#endif
