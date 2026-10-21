#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// Sidebar symbols stay visible while the window is in front. Rendered
    /// with the key window's appearance on a dark sidebar, a `Label` icon in
    /// a hierarchical style came out black; `SidebarSymbol` draws gray.
    @MainActor
    @Suite(.serialized)
    struct SidebarSymbolRenderTests {
        private static let size = NSSize(width: 240, height: 140)

        private func render(_ view: some View) async throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: view
                .listStyle(.sidebar)
                .environment(\.controlActiveState, .key)
                .frame(width: Self.size.width, height: Self.size.height))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: Self.size)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = host.appearance
            window.contentView = host
            defer { window.close() }
            for _ in 0 ..< 10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

        /// The brightest pixel in the icon column, where only the symbols are
        /// drawn (the names start further right).
        private func brightestIcon(in rep: NSBitmapImageRep) -> CGFloat {
            let scale = CGFloat(rep.pixelsWide) / Self.size.width
            var brightest: CGFloat = 0
            for x in Int(14 * scale) ..< Int(34 * scale) {
                for y in 0 ..< rep.pixelsHigh {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    brightest = max(brightest, color.brightnessComponent * color.alphaComponent)
                }
            }
            return brightest
        }

        @Test func pinnedRowAndSpaceSymbolsStayGrayInAFocusedDarkWindow() async throws {
            let rep = try await render(List {
                MentionsSidebarRow(unread: 0)
                ThreadsSidebarRow(unread: 0)
                Label("Design", sidebarSymbol: SidebarRowPicture.spaceSymbol)
            })
            // A gray symbol on the dark sidebar is far brighter than the
            // sidebar itself; a black one is not.
            #expect(brightestIcon(in: rep) > 0.4)
        }
    }
#endif
