#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The drop target keeps its content whether or not it takes drops. It
    /// drew `content` in one branch and `content.dropDestination` in another,
    /// so turning drops off, which beginning an edit does, rebuilt everything
    /// under it: the composer in the middle of its edit, and the transcript's
    /// scroll (session 60 review, Important 1).
    @MainActor
    struct FileDropTargetTests {
        final class Appearances {
            var count = 0
        }

        struct Hosted: View {
            let appearances: Appearances
            let stage: (([URL]) -> Void)?

            var body: some View {
                Text("transcript")
                    .onAppear { appearances.count += 1 }
                    .modifier(FileDropTarget(stage: stage))
            }
        }

        private func settle(_ host: NSView) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }

        @Test func turningDropsOffAndOnKeepsTheContent() {
            let appearances = Appearances()
            let host = NSHostingView(rootView: Hosted(appearances: appearances, stage: { _ in }))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = host
            settle(host)
            // The positive control: the content did appear.
            #expect(appearances.count == 1)
            host.rootView = Hosted(appearances: appearances, stage: nil)
            settle(host)
            host.rootView = Hosted(appearances: appearances, stage: { _ in })
            settle(host)
            #expect(appearances.count == 1)
            withExtendedLifetime(window) {}
        }
    }
#endif
