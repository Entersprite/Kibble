#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct SpaceNotificationSheetRenderTests {
        @Test func theProviderSettingFitsAboveTheExistingRules() async throws {
            let resolved = NotificationRule.resolve([])
            let state = ConversationRuleState(
                id: .init("space"), title: "Design", rule: NotificationRule(),
                inherited: resolved, resolved: resolved
            )
            let sheet = ConversationNotificationSheet(
                state: state, spaceNotifications: .init(
                    level: .lessWithNewThreads,
                    muted: true,
                    canSave: true
                ) { _ in },
                conversationMute: .init(pause: .until(.now.addingTimeInterval(3600)), canSave: true) { _ in }
            ) { _ in }
                .frame(width: 480, height: 440)
            let host = NSHostingView(rootView: sheet)
            let bounds = NSRect(x: 0, y: 0, width: 480, height: 440)
            let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            for _ in 0 ..< 8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(host.frame.size == bounds.size)
            if let output = ProcessInfo.processInfo.environment["KIBBLE_SPACE_SETTINGS_RENDER_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("space-notifications.png"))
            }
        }
    }
#endif
