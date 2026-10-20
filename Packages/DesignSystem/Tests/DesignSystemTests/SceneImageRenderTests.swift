#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.timeLimit(.minutes(1)))
    struct SceneImageRenderTests {
        @Test func avatarSpaceAndCallPhotosUseInjectedBytesAndReloadForAnotherScope() async throws {
            for dark in [false, true] {
                try await render(dark: dark)
            }
        }

        private func render(dark: Bool) async throws {
            let first = SceneImageRenderLog()
            let second = SceneImageRenderLog()
            let green = try picture(red: 0.1, green: 0.8)
            let red = try picture(red: 0.9, green: 0.1)
            let one = SceneImageLoader(id: UUID()) { _ in first.count += 1; return green }
            let two = SceneImageLoader(id: UUID()) { _ in second.count += 1; return red }
            let host = NSHostingView(rootView: SceneImagePreview(loader: one, dark: dark))
            host.frame.size = CGSize(width: 240, height: 220)
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let before = try await rendered(host, log: first, red: false)
            host.rootView = SceneImagePreview(loader: two, dark: dark)
            let after = try await rendered(host, log: second, red: true)
            #expect(first.count == 3)
            #expect(second.count == 3)
            #expect(before != after)
            if let output = ProcessInfo.processInfo.environment["KIBBLE_IMAGE_RENDER_DIR"] {
                let folder = URL(fileURLWithPath: output)
                try before
                    .write(to: folder.appendingPathComponent("images-\(dark ? "dark" : "light")-first.png"))
                try after
                    .write(to: folder.appendingPathComponent("images-\(dark ? "dark" : "light")-second.png"))
            }
            withExtendedLifetime(window) {}
        }

        private func rendered(
            _ host: NSHostingView<SceneImagePreview>, log: SceneImageRenderLog, red: Bool
        ) async throws -> Data {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                pump()
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if log.count == 3, hasColor(bitmap, red: red) {
                    return try #require(bitmap.representation(using: .png, properties: [:]))
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            if let output = ProcessInfo.processInfo.environment["KIBBLE_IMAGE_RENDER_DIR"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: output).appendingPathComponent("timeout-\(red)-\(log.count).png"))
            }
            Issue.record(
                "Injected pixels did not reach the native view; red=\(red), callbacks=\(log.count)"
            )
            throw CocoaError(.coderValueNotFound)
        }

        private func hasColor(_ bitmap: NSBitmapImageRep, red: Bool) -> Bool {
            var matches = 0
            for column in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                for row in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                    guard let color = bitmap.colorAt(x: column, y: row)
                    else { continue }
                    let primary = red ? color.redComponent : color.greenComponent
                    let other = red ? color.greenComponent : color.redComponent
                    if primary > 0.3, primary > other + 0.1, primary > color.blueComponent + 0.1 {
                        matches += 1
                    }
                }
            }
            return matches > 10
        }

        private func pump() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        private func picture(red: CGFloat, green: CGFloat) throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(red: red, green: green, blue: 0.2, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill()
            NSGraphicsContext.restoreGraphicsState()
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
    }

    @MainActor
    private final class SceneImageRenderLog { var count = 0 }

    private struct SceneImagePreview: View {
        let loader: SceneImageLoader
        let dark: Bool
        let url = URL(string: "https://acme.example/same-photo.png")!

        var body: some View {
            VStack(spacing: 20) {
                HStack(spacing: 30) {
                    Avatar(member: .init("person"), directory: [
                        .init("person"): Member(
                            id: .init("person"),
                            kind: .human,
                            displayName: "Demo",
                            avatarURL: url
                        )
                    ], size: 48)
                    ConversationPicture(
                        conversation: .init(id: .init("space"), kind: .space, title: "Space", avatarURL: url),
                        size: 48
                    )
                }
                CallBackdrop(photo: url).frame(width: 180, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(20)
            .frame(width: 240, height: 220)
            .background(.background)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.sceneImageLoader, loader)
        }
    }
#endif
