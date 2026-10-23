#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// A GIF in an app card's image widget or in a link card plays, as an
    /// uploaded one does, and holds its first frame under Reduce Motion. The
    /// frames are solid red then solid green, so the pixels on screen say
    /// which one is drawn.
    @MainActor
    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct AnimatedRemoteImageRenderTests {
        private static let url = URL(string: "https://media.acme.example/party/confetti.gif")!
        private static let site = URL(string: "https://outfitters.acme.example")!

        private func gif() throws -> Data {
            try TestGIF.make(colors: [(red: 0.9, green: 0.1), (red: 0.1, green: 0.9)], side: 64, delay: 0.2)
        }

        @Test(arguments: ["card", "link"])
        func aRemoteGIFPlays(kind: String) async throws {
            let seen = try await colors(
                of: view(kind: kind, data: gif(), reduceMotion: false), watching: .seconds(15), name: kind
            )
            #expect(seen.red, "The first frame never drew")
            #expect(seen.green, "The animation never reached its second frame")
        }

        @Test(arguments: ["card", "link"])
        func reduceMotionHoldsTheFirstFrame(kind: String) async throws {
            let seen = try await colors(
                of: view(kind: kind, data: gif(), reduceMotion: true), watching: .seconds(1.2)
            )
            #expect(seen.red, "The first frame never drew")
            #expect(!seen.green, "Reduce Motion still played the animation")
        }

        /// A titleless preview with a picture is the picture alone: no
        /// title row under it, so the card is exactly the image's height.
        @Test func anImageOnlyLinkCardIsOnlyThePicture() {
            let link = MessageLink(url: Self.url, preview: LinkPreview(
                title: "", imageURL: Self.url, imageWidth: 640, imageHeight: 320
            ))
            let host = NSHostingView(rootView: LinkPreviewCard(link: link, load: { _ in Data() }))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height == 160)
            #expect(host.fittingSize.width == LinkCardLayout.width)
        }

        private func view(kind: String, data: Data, reduceMotion: Bool) -> AnyView {
            let load: (URL) async throws -> Data = { _ in data }
            let content: AnyView = kind == "card"
                ? AnyView(AppCardView(
                    card: AppCard(
                        header: .init(title: RichText("#165 · Acme Outfitters is live")),
                        sections: [.init(widgets: [
                            .image(.init(url: Self.url, aspectRatio: 1)),
                            .buttons([LinkButton(label: "Open the site", url: Self.site)])
                        ])]
                    ),
                    load: load
                ))
                : AnyView(LinkPreviewCard(
                    link: MessageLink(url: Self.url, preview: LinkPreview(
                        title: "", imageURL: Self.url, imageWidth: 160, imageHeight: 160
                    )),
                    load: load
                ))
            return AnyView(content
                .padding(16)
                .frame(width: 360)
                .background(.background)
                .environment(\.colorScheme, .light)
                .environment(\._accessibilityReduceMotion, reduceMotion))
        }

        /// Renders until both frames have drawn, or for `watching` once the
        /// first has: several 0.2-second frames, with room for a loaded
        /// machine running the other hosted suites. With
        /// `KIBBLE_IMAGE_RENDER_DIR` set, `name` writes the first render of
        /// each frame there for inspection.
        private func colors(
            of view: AnyView, watching: Duration, name: String? = nil
        ) async throws -> (red: Bool, green: Bool) {
            let output = name.flatMap { name in
                ProcessInfo.processInfo.environment["KIBBLE_IMAGE_RENDER_DIR"].map {
                    URL(fileURLWithPath: $0).appendingPathComponent("gif-\(name)")
                }
            }
            let host = NSHostingView(rootView: view)
            host.frame.size = host.fittingSize
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            var red = false
            var green = false
            var redAt: ContinuousClock.Instant?
            let deadline = ContinuousClock.now + .seconds(25)
            while ContinuousClock.now < deadline {
                pump()
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if !red, dominant(bitmap, red: true) {
                    red = true
                    redAt = .now
                    try output.map { try bitmap.representation(using: .png, properties: [:])?
                        .write(to: $0.appendingPathExtension("first.png"))
                    }
                }
                if !green, dominant(bitmap, red: false) {
                    green = true
                    try output.map { try bitmap.representation(using: .png, properties: [:])?
                        .write(to: $0.appendingPathExtension("second.png"))
                    }
                }
                if let redAt, ContinuousClock.now - redAt > watching || (red && green) {
                    break
                }
                // Well under one 0.2-second frame, and idle enough not to
                // starve the other hosted suites sharing the main actor.
                try await Task.sleep(for: .milliseconds(40))
            }
            return (red, green)
        }

        private func pump() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        private func dominant(_ bitmap: NSBitmapImageRep, red: Bool) -> Bool {
            var matches = 0
            for column in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                for row in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                    guard let color = bitmap.colorAt(x: column, y: row) else { continue }
                    let primary = red ? color.redComponent : color.greenComponent
                    let other = red ? color.greenComponent : color.redComponent
                    if primary > 0.5, primary > other + 0.3 {
                        matches += 1
                    }
                }
            }
            return matches > 10
        }
    }
#endif
