#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct MeetingLinkCardRenderTests {
        @Test(arguments: [false, true])
        func meetingCardsFitNarrowMessagesWithoutShowingWindows(_ dark: Bool) throws {
            let url = try #require(URL(string: "https://meet.example/abc-defg-hij"))
            let root = VStack(alignment: .leading, spacing: 16) {
                MeetingLinkCard(link: MessageLink(url: url, preview: LinkPreview(title: "Weekly planning")))
                MeetingLinkCard(link: MessageLink(url: url, preview: LinkPreview(
                    title: "A longer meeting name that should wrap without hiding either action"
                )))
                MeetingLinkCard(link: MessageLink(url: url))
            }
            .environment(\.joinMeetingLink) { _, _, _ in }
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(16).frame(width: 280).background(.background)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.width == 280 && host.frame.height > 250)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["KIBBLE_MEETING_CARD_RENDER_DIR"] {
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(
                        dark ? "meeting-cards-dark.png" : "meeting-cards-light.png"
                    ))
            }
        }
    }
#endif
