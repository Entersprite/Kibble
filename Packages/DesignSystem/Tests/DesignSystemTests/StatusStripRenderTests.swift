#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct StatusStripRenderTests {
        @Test func startupAndFailureStripsFitANarrowWindow() throws {
            for dark in [false, true] {
                let states: [ChatSceneState] = [
                    .init(connection: .connecting),
                    .init(connection: .reconnecting(attempt: 1, issue: .noInternet, detail: nil)),
                    .init(connection: .connecting, lastError: .notAuthenticated)
                ]
                let preview = VStack(alignment: .leading, spacing: 16) {
                    ForEach(states.indices, id: \.self) { index in
                        StatusStrip(state: states[index], actions: .init())
                    }
                }
                .padding(.vertical, 12).frame(width: 360).background(.background)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: preview)
                host.frame.size = host.fittingSize
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true
                )
                window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                #expect(host.frame.width == 360)
                #expect(host.frame.height > 90)
                if let output = ProcessInfo.processInfo.environment["KIBBLE_STATUS_RENDER_DIR"] {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: output)
                        .appendingPathComponent("status-\(dark ? "dark" : "light").png"))
                }
                withExtendedLifetime(window) {}
            }
        }
    }
#endif
