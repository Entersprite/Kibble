#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The Info sheet presented as a real sheet, because its footer buttons
    /// and their key equivalents exist only in the sheet's own bottom bar.
    @MainActor @Suite(.serialized)
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

        @Observable @MainActor final class Scene {
            var state = ChatSceneState()
        }

        /// The window's real presentation: one sheet whose content follows the model.
        struct PanelHost: View {
            let scene: Scene
            let actions: ChatSceneActions

            var body: some View {
                Color.clear
                    .frame(width: 1400, height: 1000)
                    .modifier(ConversationPanelPresentation(state: scene.state, actions: actions))
            }
        }

        private static let space = Conversation.ID("space")

        private static func details(_ id: Conversation.ID = space) -> ConversationDetails {
            ConversationDetails(
                conversation: Conversation(id: id, kind: .space, title: "Design Team", memberCount: 8),
                membership: .joined,
                settings: ConversationSettings()
            )
        }

        /// Info opens as the model does: the sheet first shows Loading, then the
        /// same presentation swaps to Info once details arrive. The window must
        /// grow to Info's remembered size and stay resizable, not keep Loading's
        /// 380-point window with Info clipped inside it at its minimum.
        @Test func infoOpensAtItsRememberedSizeAfterLoading() async throws {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "conversationInfo.width")
            defaults.removeObject(forKey: "conversationInfo.height")
            let (window, scene) = presentPanel()
            defer { window.close() }
            let sheet = try #require(try await waitForSheet(on: window), "The panel must be presented.")
            try await settle(sheet) { $0.height < 300 }
            let loading = contentSize(sheet)
            #expect(abs(loading.width - 380) < 1, "Loading: \(loading)")
            // The sheet's button bar sits below the content, outside its frame.
            let bar = loading.height - 200

            scene.state.browser.details = Self.details()
            try await settle(sheet) { $0.width >= 759 }
            try capture(sheet, name: "info-after-loading")
            let window1 = contentSize(sheet)
            #expect(abs(window1.width - 760) < 1 && abs(window1.height - (560 + bar)) < 1, "Info: \(window1)")
            let info = try #require(sizer(in: sheet), "Info's sizer must be in the sheet.").bounds.size
            #expect(info == CGSize(width: 760, height: 560), "Info is laid out at its ideal size: \(info)")
            #expect(sheet.styleMask.contains(.resizable), "Info stays resizable.")
            #expect(sheet.contentMinSize == CGSize(width: 640, height: 440 + bar), "\(sheet.contentMinSize)")
            #expect(defaults.object(forKey: "conversationInfo.width") == nil, "Opening saves nothing.")

            // The person resizes it; that size is remembered once, at the end.
            var resized = sheet.frame
            resized.size = sheet.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 900, height: 700 + bar))
                .size
            sheet.setFrame(resized, display: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(sheet.contentMinSize == CGSize(width: 640, height: 440 + bar), "Held while resizing.")
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: sheet)
            #expect(defaults.double(forKey: "conversationInfo.width") == 900)
            #expect(defaults.double(forKey: "conversationInfo.height") == 700)

            // Another conversation's Info loads through Loading again, which
            // keeps its own fixed size and is not left resizable.
            scene.state.browser.details = nil
            scene.state.browser.panelTarget = .init("other")
            try await settle(sheet) { $0.width < 400 }
            let reloading = contentSize(sheet)
            #expect(reloading == loading, "Loading again: \(reloading)")
            #expect(!sheet.styleMask.contains(.resizable), "Loading is not resizable.")
            scene.state.browser.details = Self.details(.init("other"))
            try await settle(sheet) { $0.width >= 899 }
            let again = contentSize(sheet)
            #expect(abs(again.width - 900) < 1 && abs(again.height - (700 + bar)) < 1, "Info again: \(again)")
            #expect(sheet.styleMask.contains(.resizable))
        }

        /// A remembered size larger than the screen opens no larger than the screen.
        @Test func aRememberedSizeIsClampedToTheScreen() async throws {
            let defaults = UserDefaults.standard
            defaults.set(5000.0, forKey: "conversationInfo.width")
            defaults.set(5000.0, forKey: "conversationInfo.height")
            defer {
                defaults.removeObject(forKey: "conversationInfo.width")
                defaults.removeObject(forKey: "conversationInfo.height")
            }
            let (window, scene) = presentPanel()
            defer { window.close() }
            let sheet = try #require(try await waitForSheet(on: window), "The panel must be presented.")
            try await settle(sheet) { $0.height < 300 }
            scene.state.browser.details = Self.details()
            try await settle(sheet) { $0.width >= 759 }
            let screen = try #require(sheet.screen ?? NSScreen.main).visibleFrame.size
            let size = contentSize(sheet)
            #expect(size.width >= 760 && size.width <= screen.width, "\(size) on \(screen)")
            #expect(size.height >= 505 && size.height <= screen.height, "\(size) on \(screen)")
        }

        private func sizer(in window: NSWindow) -> NSView? {
            func find(_ view: NSView) -> NSView? {
                view is SheetSizerView ? view : view.subviews.lazy.compactMap(find).first
            }
            return window.contentView.flatMap(find)
        }

        /// Info shown when the sheet is presented, with no Loading before it,
        /// still holds its minimum and remembers the person's size.
        @Test func infoPresentedDirectlyHoldsItsMinimumAndRemembersItsSize() async throws {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "conversationInfo.width")
            defaults.removeObject(forKey: "conversationInfo.height")
            defer {
                defaults.removeObject(forKey: "conversationInfo.width")
                defaults.removeObject(forKey: "conversationInfo.height")
            }
            let (window, _) = presentPanel(details: Self.details())
            defer { window.close() }
            let sheet = try #require(try await waitForSheet(on: window), "The panel must be presented.")
            try await settle(sheet) { $0.width >= 759 }
            let info = try #require(sizer(in: sheet)).bounds.size
            #expect(info == CGSize(width: 760, height: 560), "\(info)")
            let bar = contentSize(sheet).height - info.height
            var resized = sheet.frame
            resized.size = sheet.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 820, height: 600 + bar))
                .size
            sheet.setFrame(resized, display: true)
            try await Task.sleep(for: .milliseconds(200))
            #expect(sheet.contentMinSize == CGSize(width: 640, height: 440 + bar), "\(sheet.contentMinSize)")
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: sheet)
            #expect(defaults.double(forKey: "conversationInfo.width") == 820)
            #expect(defaults.double(forKey: "conversationInfo.height") == 600)
        }

        private func presentPanel(details: ConversationDetails? = nil) -> (NSWindow, Scene) {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let scene = Scene()
            scene.state.browser.panelTarget = Self.space
            scene.state.browser.details = details
            var actions = ChatSceneActions()
            actions.browser = self.actions(Counts())
            let window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: 1400, height: 1000),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PanelHost(scene: scene, actions: actions))
            window.orderFront(nil)
            return (window, scene)
        }

        private func contentSize(_ sheet: NSWindow) -> CGSize {
            sheet.contentRect(forFrameRect: sheet.frame).size
        }

        /// Waits in short slices for the sheet's content size to satisfy `done`,
        /// then a little longer so an animation can finish.
        private func settle(_ sheet: NSWindow, until done: (CGSize) -> Bool) async throws {
            for _ in 0 ..< 30 where !done(contentSize(sheet)) {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(400))
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
