#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The Info sheet presented as a real sheet, because its footer buttons
    /// and their key equivalents exist only in the sheet's own bottom bar.
    @MainActor @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct ConversationInfoSheetHostedTests {
        @MainActor final class Counts {
            var reverts = 0
            var saves = 0
            var closes = 0
        }

        @Observable @MainActor final class Presentation {
            var shown = true
        }

        struct Host<Sheet: View>: View {
            @Bindable var presentation: Presentation
            let sheet: Sheet

            var body: some View {
                Color.clear
                    .frame(width: 1000, height: 800)
                    .sheet(isPresented: $presentation.shown) { sheet }
            }
        }

        private func actions(_ counts: Counts) -> ConversationBrowserActions {
            ConversationBrowserActions(
                show: { _ in }, back: {}, search: { _, _, _ in }, reviewCreation: {},
                searchPeople: { _ in }, beginCreation: { _ in }, create: { _ in },
                closePanel: { counts.closes += 1 },
                details: { _, _ in }, preview: { _ in }, mutate: { _ in }
            )
        }

        /// Escape with unsaved edits must ask Save / Don't Save / Cancel. Before
        /// the fix, Revert took Escape as the cancellation action and silently
        /// discarded the draft. Return stays Save, never Revert.
        @Test func escapeWithADraftAsksInsteadOfDiscardingIt() async throws {
            let counts = Counts()
            let draft = InfoSectionDraft(
                section: .people, isValid: true,
                save: { counts.saves += 1 },
                revert: { counts.reverts += 1 }
            )
            let (window, presentation) = present(draft: draft, counts: counts)
            defer {
                presentation.shown = false
                window.close()
            }
            let infoSheet = try #require(
                try await waitForSheet(on: window),
                "The Info sheet must be presented."
            )
            try await Task.sleep(for: .milliseconds(300))
            try capture(infoSheet, name: "info-draft-sheet")

            try press("\u{1b}", keyCode: 53, in: infoSheet)
            let alert = try await waitForSheet(on: infoSheet)
            #expect(counts.reverts == 0, "Escape must not discard the draft.")
            #expect(counts.closes == 0, "Escape must not close the sheet over a draft.")
            #expect(counts.saves == 0)
            #expect(alert != nil, "Escape with a draft asks Save, Don’t Save or Cancel.")
            if let alert {
                try capture(alert, name: "info-draft-alert")
                infoSheet.endSheet(alert)
            }
            try await Task.sleep(for: .milliseconds(300))

            try press("\r", keyCode: 36, in: infoSheet)
            try await Task.sleep(for: .milliseconds(300))
            #expect(counts.saves == 1, "Return saves the draft.")
            #expect(counts.reverts == 0, "Return never reverts.")
        }

        private func present(draft: InfoSectionDraft, counts: Counts) -> (NSWindow, Presentation) {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            var state = ChatSceneState()
            state.browser.isLoadingParticipants = true
            let details = ConversationDetails(
                conversation: Conversation(
                    id: .init("space"), kind: .space, title: "Design Team", memberCount: 8
                ),
                membership: .joined,
                settings: ConversationSettings()
            )
            let presentation = Presentation()
            let window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 800),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Host(
                presentation: presentation,
                sheet: ConversationInfoSheet(
                    details: details, state: state, actions: actions(counts),
                    media: nil, openNotifications: nil, draft: draft
                )
            ))
            window.orderFront(nil)
            return (window, presentation)
        }

        private func waitForSheet(on window: NSWindow) async throws -> NSWindow? {
            for _ in 0 ..< 30 {
                if let sheet = window.attachedSheet {
                    return sheet
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        /// AppKit's order: key equivalents (a sheet button's Escape or Return)
        /// first, then the responder chain (`onExitCommand`).
        private func press(_ key: String, keyCode: UInt16, in window: NSWindow) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: keyCode
            ))
            if !window.performKeyEquivalent(with: event) {
                window.sendEvent(event)
            }
        }

        private func capture(_ window: NSWindow, name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["KIBBLE_RENDER_CAPTURE_DIR"],
                  let view = window.contentView?.superview else { return }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(name).png"))
        }
    }
#endif
