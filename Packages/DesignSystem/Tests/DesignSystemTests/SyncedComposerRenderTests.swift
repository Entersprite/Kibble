#if os(macOS)
    import AppKit
    import ChatKit
    import Observation
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct SyncedComposerRenderTests {
        @Test(arguments: [false, true])
        func conflictedComposerKeepsTextAndCanRestoreTheSavedVersion(_ dark: Bool) async throws {
            let fixture = DraftRenderFixture()
            let content = DraftRenderView(fixture: fixture)
                .frame(width: 360, height: 130, alignment: .bottom)
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }

            try await waitUntil(host: host) {
                field(in: host)?.string == "My local text" && fixture.opens == 1
            }
            try render(host, dark: dark)
            fixture.revokedOffer = true
            try clickUseSavedDraft(in: window)
            try await waitUntil(host: host) { fixture.checkedOffers == 1 }
            #expect(field(in: host)?.string == fixture.text)

            fixture.revokedOffer = false
            try clickUseSavedDraft(in: window)
            try await waitUntil(host: host) { field(in: host)?.string == "Restored web text" }
            #expect(fixture.adopted?.text == "Restored web text")
        }

        @Test(arguments: [false, true])
        func returnSubmitsTheOriginalCompositionWithTheTrimmedMessage(staged: Bool) async throws {
            let fixture = DraftRenderFixture(text: "  Send this text  ", conflict: false)
            let attachments: [ComposerAttachment] = staged ? [ComposerAttachment(
                id: "staged", name: "fixture.txt", byteSize: 12, isImage: false,
                file: URL(fileURLWithPath: "/nonexistent/fixture.txt")
            )] : []
            let host = NSHostingView(rootView: DraftRenderView(fixture: fixture, attachments: attachments))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await waitUntil(host: host) { field(in: host)?.string == fixture.text }
            let editor = try #require(field(in: host))
            #expect(window.makeFirstResponder(editor))
            let enter = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
            window.sendEvent(enter)
            try await waitUntil(host: host) { field(in: host)?.string.isEmpty == true }
            #expect(fixture.sent?.message.text == "Send this text")
            #expect(fixture.sent?.draft.text == fixture.text)
            #expect(fixture.ordinarySends == 0)
        }

        private func clickUseSavedDraft(in window: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 74, y: 52), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
            }
        }

        private func field(in view: NSView) -> NSTextView? {
            if let field = view as? NSTextView {
                return field
            }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }

        private func waitUntil(host: NSView, _ ready: () -> Bool) async throws {
            for _ in 0 ..< 150 where !ready() {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(ready())
        }

        private func render(_ host: NSView, dark: Bool) throws {
            guard let directory = ProcessInfo.processInfo.environment["KIBBLE_SYNC_DRAFT_RENDER_DIR"]
            else { return }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                    dark ? "draft-conflict-dark.png" : "draft-conflict-light.png"
                ))
        }
    }

    @MainActor
    private struct DraftRenderView: View {
        let fixture: DraftRenderFixture
        var attachments: [ComposerAttachment] = []

        var body: some View {
            Composer(
                placeholder: "Team", attachments: attachments, initialDraft: fixture.initial,
                draftSync: fixture.actions, send: { _ in fixture.ordinarySends += 1 }
            )
        }
    }

    @MainActor
    @Observable
    private final class DraftRenderFixture {
        var status = ComposerDraftSyncStatus()
        var opens = 0
        var adopted: ComposedMessage?
        var sent: (message: ComposedMessage, draft: ComposedMessage)?
        var ordinarySends = 0
        var revokedOffer = false
        var checkedOffers = 0
        let text: String

        init(text: String = "My local text", conflict: Bool = true) {
            self.text = text
            status.conflict = conflict
        }

        var initial: ComposerDraft {
            var draft = ComposerDraft()
            draft.edit(text)
            return draft
        }

        var actions: ComposerDraftSync {
            ComposerDraftSync(
                connected: true, status: status, opened: { self.opens += 1 },
                resolved: { _, local, applied in
                    if applied {
                        self.adopted = local
                    }
                    self.status = ComposerDraftSyncStatus()
                },
                useSaved: useSaved, keepLocal: {}, submitted: { _ in },
                send: { self.sent = ($0, $1) },
                isCurrentOffer: { _ in
                    self.checkedOffers += 1
                    return !self.revokedOffer
                }
            )
        }

        func useSaved() {
            status.replacement = ComposerDraftReplacement(
                id: UUID(), expected: initial.syncedComposition,
                body: ComposedMessage(text: "Restored web text")
            )
        }
    }
#endif
