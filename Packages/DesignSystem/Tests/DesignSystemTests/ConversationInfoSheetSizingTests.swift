#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// Info's window size through the panel's real presentation: one sheet
    /// whose content follows the model, so Info usually replaces Loading or
    /// Preview in a sheet that is already shown.
    @MainActor @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct ConversationInfoSheetSizingTests {
        @Observable @MainActor final class Scene {
            var state = ChatSceneState()
        }

        struct PanelHost: View {
            let scene: Scene
            let actions: ChatSceneActions

            var body: some View {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(ConversationPanelPresentation(state: scene.state, actions: actions))
            }
        }

        private static let space = Conversation.ID("space")
        private static let keys = ["conversationInfo.width", "conversationInfo.height"]

        private static func details(
            _ id: Conversation.ID = space,
            membership: ParticipantState = .joined
        ) -> ConversationDetails {
            ConversationDetails(
                conversation: Conversation(id: id, kind: .space, title: "Design Team", memberCount: 8),
                membership: membership,
                allowedActions: membership == .joined ? [] : ["acceptInvitation"],
                settings: ConversationSettings()
            )
        }

        /// Sets the remembered size, or forgets it with nil.
        private static func remember(_ size: CGSize?) {
            for (key, value) in zip(keys, [size?.width, size?.height]) {
                if let value {
                    UserDefaults.standard.set(Double(value), forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        /// Info opens as the model does: the sheet first shows Loading, then the
        /// same presentation swaps to Info once details arrive. The window must
        /// grow to Info's remembered size and stay resizable, not keep Loading's
        /// 380-point window with Info clipped inside it at its minimum.
        @Test func infoOpensAtItsRememberedSizeAfterLoading() async throws {
            let defaults = UserDefaults.standard
            Self.remember(nil)
            defer { Self.remember(nil) }
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
            let opened = contentSize(sheet)
            #expect(abs(opened.width - 760) < 1 && abs(opened.height - (560 + bar)) < 1, "Info: \(opened)")
            let info = try #require(sizer(in: sheet), "Info's sizer must be in the sheet.").bounds.size
            #expect(info == CGSize(width: 760, height: 560), "Info is laid out at its ideal size: \(info)")
            #expect(sheet.contentMinSize == CGSize(width: 640, height: 440 + bar), "\(sheet.contentMinSize)")
            #expect(defaults.object(forKey: Self.keys[0]) == nil, "Opening saves nothing.")
            try expectUserResizable(sheet)

            // The person resizes it; that size is remembered once, at the end.
            try resize(sheet, to: CGSize(width: 900, height: 700 + bar))
            try await Task.sleep(for: .milliseconds(300))
            #expect(sheet.contentMinSize == CGSize(width: 640, height: 440 + bar), "Held while resizing.")
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: sheet)
            #expect(defaults.double(forKey: Self.keys[0]) == 900)
            #expect(defaults.double(forKey: Self.keys[1]) == 700)

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
            try expectUserResizable(sheet)
        }

        /// Joining a space from its preview swaps Preview's fixed sheet for Info.
        @Test func infoOpensAtItsRememberedSizeAfterPreview() async throws {
            Self.remember(nil)
            defer { Self.remember(nil) }
            let (window, scene) = presentPanel(details: Self.details(membership: .invited))
            defer { window.close() }
            let sheet = try #require(try await waitForSheet(on: window), "The panel must be presented.")
            try await settle(sheet) { $0.width >= 559 }
            let preview = contentSize(sheet)
            #expect(abs(preview.width - 560) < 1, "Preview: \(preview)")
            #expect(!sheet.styleMask.contains(.resizable), "Preview is not resizable.")

            scene.state.browser.details = Self.details()
            try await settle(sheet) { $0.width >= 759 }
            let info = try #require(sizer(in: sheet)).bounds.size
            #expect(info == CGSize(width: 760, height: 560), "Info after Preview: \(info)")
            try expectUserResizable(sheet)
        }

        /// A remembered size larger than the screen opens no larger than it.
        @Test func aRememberedSizeIsClampedToTheScreen() async throws {
            Self.remember(CGSize(width: 5000, height: 5000))
            defer { Self.remember(nil) }
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

        /// A sheet taller than its parent hangs from the top of the parent's
        /// content, so a tall remembered size must stop at the bottom of the
        /// screen, keeping Done and Save above the Dock without AppKit moving
        /// the person's window. The screen's whole height would do both here.
        @Test func aTallRememberedSizeKeepsTheFooterOnScreen() async throws {
            let visible = try #require(NSScreen.main).visibleFrame
            Self.remember(CGSize(width: 760, height: 5000))
            defer { Self.remember(nil) }
            let parent = NSRect(x: visible.midX - 500, y: visible.minY + 20, width: 1000, height: 600)
            let (window, scene) = presentPanel(frame: parent)
            defer { window.close() }
            let sheet = try #require(try await waitForSheet(on: window), "The panel must be presented.")
            try await settle(sheet) { $0.height < 300 }
            let bar = contentSize(sheet).height - 200
            let placed = window.frame
            let top = window.convertToScreen(window.contentLayoutRect).maxY
            #expect(visible.height - bar > top - visible.minY, "The screen-height limit would overflow.")

            scene.state.browser.details = Self.details()
            try await settle(sheet) { $0.width >= 759 }
            #expect(window.frame == placed, "The parent stays where it was: \(window.frame)")
            #expect(sheet.frame.minY >= visible.minY - 0.5, "\(sheet.frame) on \(visible)")
            #expect(sheet.frame.maxY <= top + 0.5, "\(sheet.frame) below \(top)")
            let info = try #require(sizer(in: sheet)).bounds.size
            #expect(info.height >= 440 && info.height <= top - visible.minY - bar + 0.5, "\(info)")
            #expect(info.height > 500, "The sheet still uses the room it has: \(info)")
        }

        /// Info shown when the sheet is presented, with no Loading before it,
        /// still holds its minimum and remembers the person's size.
        @Test func infoPresentedDirectlyHoldsItsMinimumAndRemembersItsSize() async throws {
            let defaults = UserDefaults.standard
            Self.remember(nil)
            defer { Self.remember(nil) }
            let (window, _) = presentPanel(details: Self.details())
            defer { window.close() }
            let sheet = try #require(try await waitForSheet(on: window), "The panel must be presented.")
            try await settle(sheet) { $0.width >= 759 }
            let info = try #require(sizer(in: sheet)).bounds.size
            #expect(info == CGSize(width: 760, height: 560), "\(info)")
            let bar = contentSize(sheet).height - info.height
            try resize(sheet, to: CGSize(width: 820, height: 600 + bar))
            try await Task.sleep(for: .milliseconds(200))
            #expect(sheet.contentMinSize == CGSize(width: 640, height: 440 + bar), "\(sheet.contentMinSize)")
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: sheet)
            #expect(defaults.double(forKey: Self.keys[0]) == 820)
            #expect(defaults.double(forKey: Self.keys[1]) == 600)
        }

        /// What a person's drag goes through, which `setFrame` bypasses: the
        /// resizable style, the maximum, and the delegate's say over the size.
        private func expectUserResizable(_ sheet: NSWindow) throws {
            #expect(sheet.styleMask.contains(.resizable), "Info is resizable.")
            let screen = try #require(sheet.screen ?? NSScreen.main).visibleFrame.size
            #expect(
                sheet.contentMaxSize.width >= screen.width && sheet.contentMaxSize.height >= screen.height,
                "Maximum: \(sheet.contentMaxSize)"
            )
            let larger = NSSize(width: sheet.frame.width + 200, height: sheet.frame.height + 150)
            if let allowed = sheet.delegate?.windowWillResize?(sheet, to: larger) {
                #expect(allowed == larger, "The delegate caps a drag at \(allowed).")
            }
        }

        private func resize(_ sheet: NSWindow, to content: CGSize) throws {
            var frame = sheet.frame
            frame.size = sheet.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
            sheet.setFrame(frame, display: true)
        }

        private func presentPanel(
            details: ConversationDetails? = nil,
            frame: NSRect? = nil
        ) -> (NSWindow, Scene) {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let scene = Scene()
            scene.state.browser.panelTarget = Self.space
            scene.state.browser.details = details
            var actions = ChatSceneActions()
            actions.browser = ConversationBrowserActions(
                show: { _ in }, back: {}, search: { _, _, _ in }, reviewCreation: {},
                searchPeople: { _ in }, beginCreation: { _ in }, create: { _ in },
                closePanel: {}, details: { _, _ in }, preview: { _ in }, mutate: { _ in }
            )
            // AppKit moves a titled window onto the screen anyway, and a sheet's
            // room depends on where it hangs: put it at the top, out of sight.
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
            let height = min(1000, visible.height - 40)
            let window = NSWindow(
                contentRect: frame ?? NSRect(
                    x: visible.minX,
                    y: visible.maxY - height - 30,
                    width: 1400,
                    height: height
                ),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let host = NSHostingView(rootView: PanelHost(scene: scene, actions: actions))
            // The window keeps the frame the test gives it.
            host.sizingOptions = []
            window.contentView = host
            window.orderFront(nil)
            return (window, scene)
        }

        private func sizer(in window: NSWindow) -> NSView? {
            func find(_ view: NSView) -> NSView? {
                view is SheetSizerView ? view : view.subviews.lazy.compactMap(find).first
            }
            return window.contentView.flatMap(find)
        }

        private func waitForSheet(on window: NSWindow) async throws -> NSWindow? {
            for _ in 0 ..< 30 {
                if let sheet = window.attachedSheet {
                    sheet.alphaValue = 0
                    return sheet
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return nil
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
    }
#endif
