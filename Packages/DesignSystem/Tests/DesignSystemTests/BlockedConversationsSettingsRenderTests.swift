#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct BlockedConversationsSettingsRenderTests {
        @Test(arguments: [false, true], [false, true])
        func theNativeUnblockButtonUsesTheRowIdentity(_ dark: Bool, people: Bool) async throws {
            var selected: String?
            let content = pane(people: people) { selected = $0 }
                .frame(width: 560, height: 360)
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            for _ in 0 ..< 10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(host.frame.size == CGSize(width: 560, height: 360))
            try capture(host, dark: dark, people: people)
            let location = NSPoint(x: host.bounds.width - 49, y: host.bounds.height - 72)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1
                ))
                window.sendEvent(event)
            }
            #expect(selected == (people ? "person" : "room"))
        }

        @ViewBuilder private func pane(people: Bool, unblock: @escaping (String) -> Void) -> some View {
            if people {
                BlockedPeopleSettingsPane(
                    state: .init(
                        rows: [.init(id: .init("person"), name: "Fixture Person")],
                        isAvailable: true,
                        isLoading: false,
                        pending: nil,
                        error: nil
                    ),
                    actions: .init(refresh: {}, unblock: { unblock($0.rawValue) })
                )
            } else {
                BlockedConversationsSettingsPane(
                    state: .init(
                        rows: [.init(id: .init("room"), name: "Fixture Room")],
                        isAvailable: true,
                        isLoading: false,
                        pending: nil,
                        error: nil
                    ),
                    actions: .init(refresh: {}, unblock: { unblock($0.rawValue) })
                )
            }
        }

        private func capture(_ host: NSView, dark: Bool, people: Bool) throws {
            guard let path = ProcessInfo.processInfo.environment["KIBBLE_BLOCKED_ROOMS_RENDER_DIR"] else {
                return
            }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let appearance = dark ? "dark" : "light"
            let name = people ? "people-\(appearance).png" : "\(appearance).png"
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
        }
    }
#endif
