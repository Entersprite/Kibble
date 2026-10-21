#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The Set a Status sheet presented as a real sheet: its buttons sit in
    /// the sheet's own placements, which give Save the Return key and Cancel
    /// the Escape key, as the hand-placed buttons had them.
    @MainActor @Suite(.serialized)
    struct SetStatusSheetTests {
        private final class Saved {
            var statuses: [MemberStatus?] = []
        }

        @Test func returnSavesTheStatus() async throws {
            let current = MemberStatus(emoji: "🏠", text: "Working remotely", expiresAt: nil)
            let saved = Saved()
            let sheet = try await PresentedSheet.present(current: current, saved: saved)
            defer { sheet.close() }
            try await sheet.press(keyCode: 36, characters: "\r")
            #expect(saved.statuses == [current])
            #expect(!sheet.isPresented)
        }

        /// Nothing typed and nothing chosen: Save is off, so Return sends
        /// nothing and the sheet stays; Escape then cancels it.
        @Test func returnWaitsForSomethingToSaveAndEscapeCancels() async throws {
            let saved = Saved()
            let sheet = try await PresentedSheet.present(current: nil, saved: saved)
            defer { sheet.close() }
            try await sheet.press(keyCode: 36, characters: "\r")
            #expect(saved.statuses.isEmpty)
            #expect(sheet.isPresented)
            try await sheet.press(keyCode: 53, characters: "\u{1B}")
            #expect(saved.statuses.isEmpty)
            #expect(!sheet.isPresented)
        }

        @MainActor
        private struct PresentedSheet {
            let window: NSWindow

            static func present(current: MemberStatus?, saved: Saved) async throws -> PresentedSheet {
                _ = NSApplication.shared
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.titled],
                    backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: Host(current: current, saved: saved))
                // A sheet is attached only to a window on screen.
                window.orderFront(nil)
                try await turn(until: { window.attachedSheet != nil })
                // A few more, so the sheet's buttons are in place before a key arrives.
                try await turn(until: { false }, atMost: 5)
                try #require(window.attachedSheet != nil)
                return PresentedSheet(window: window)
            }

            var isPresented: Bool {
                window.attachedSheet != nil
            }

            func press(keyCode: UInt16, characters: String) async throws {
                let sheet = try #require(window.attachedSheet)
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: sheet.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
                ))
                // The window is not key in a test process, so a key
                // equivalent goes to it directly, as the app would send it.
                if !sheet.performKeyEquivalent(with: event) {
                    sheet.sendEvent(event)
                }
                try await Self.turn(until: { [window] in window.attachedSheet == nil })
            }

            func close() {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
                window.close()
            }

            /// Runs the loop until `done`, or about half a second at most: a
            /// sheet that stays up is a result too. Each turn yields, so other
            /// tests on the main actor keep their own time.
            private static func turn(until done: () -> Bool, atMost limit: Int = 25) async throws {
                for _ in 0 ..< limit where !done() {
                    pump()
                    try await Task.sleep(for: .milliseconds(10))
                }
            }

            private static func pump() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }

        private struct Host: View {
            let current: MemberStatus?
            let saved: Saved
            @State private var isPresented = true

            var body: some View {
                Color.clear
                    .frame(width: 600, height: 560)
                    .sheet(isPresented: $isPresented) {
                        SetStatusSheet(current: current, reactions: nil) { saved.statuses.append($0) }
                    }
            }
        }
    }
#endif
