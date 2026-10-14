#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.serialized)
    struct MediaSlotHostedTests {
        @MainActor
        private final class Gate {
            var pending: [CheckedContinuation<Data, any Error>] = []
            var requests = 0
            var released = false
            let data: Data
            let fail: Bool

            init(data: Data, fail: Bool) {
                self.data = data
                self.fail = fail
            }

            func load() async throws -> Data {
                requests += 1
                if released {
                    return try result()
                }
                return try await withCheckedThrowingContinuation { pending.append($0) }
            }

            func release() {
                released = true
                let waiting = pending
                pending.removeAll()
                for continuation in waiting {
                    continuation.resume(with: Result { try result() })
                }
            }

            private func result() throws -> Data {
                if fail {
                    throw CocoaError(.fileReadUnknown)
                }
                return data
            }
        }

        private func image() throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 400,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }

        @Test(
            arguments: ["link-unknown", "link-declared", "attachment-unknown", "attachment-declared", "card"],
            [false, true]
        )
        func delayedImageCompletionKeepsTheOriginalSlot(kind: String, fail: Bool) async throws {
            let data = try image()
            #expect(AttachmentLayout.decode(data) != nil)
            let gate = Gate(data: data, fail: fail)
            let url = try #require(URL(string: "https://acme.example/offline.png"))
            let view = mediaView(kind: kind, url: url, gate: gate)
            let host = NSHostingView(rootView: AnyView(view.frame(width: 360)
                    .fixedSize(horizontal: false, vertical: true)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { gate.release(); window.close() }
            for _ in 0 ..< 100 where gate.requests == 0 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(gate.requests > 0, "The placeholder must actually start a delayed load")
            let before = host.fittingSize
            #expect(before.height > 40)
            gate.release()
            var largestChange: CGFloat = 0
            for _ in 0 ..< 100 {
                try await Task.sleep(for: .milliseconds(2))
                host.layoutSubtreeIfNeeded()
                largestChange = max(largestChange, abs(host.fittingSize.height - before.height))
            }
            #expect(largestChange < 1, "Image completion moved the row by \(largestChange) points")
        }

        private func mediaView(kind: String, url: URL, gate: Gate) -> AnyView {
            switch kind {
            case "link-unknown", "link-declared":
                AnyView(LinkPreviewCard(
                    link: MessageLink(url: url, preview: LinkPreview(
                        title: "Offline image", imageURL: url,
                        imageWidth: kind == "link-declared" ? 800 : nil,
                        imageHeight: kind == "link-declared" ? 200 : nil
                    )), load: { _ in try await gate.load() }
                ))
            case "attachment-unknown", "attachment-declared":
                AnyView(AttachmentImage(
                    attachment: Attachment(
                        id: "offline-image", name: "image.png", contentType: "image/png",
                        width: kind == "attachment-declared" ? 800 : nil,
                        height: kind == "attachment-declared" ? 200 : nil
                    ), load: { _, _ in try await gate.load() }, open: nil
                ))
            default:
                AnyView(AppCardView(card: AppCard(
                    header: .init(title: RichText("Offline header"), imageURL: url),
                    sections: [.init(widgets: [
                        .decorated(.init(content: RichText("Offline row"), iconURL: url)),
                        .image(.init(url: url))
                    ])]
                ), load: { _ in try await gate.load() }))
            }
        }

        @Test(arguments: [nil, 0, -1, Double.infinity, Double.nan, 2])
        func cardImageAspectHandlesMissingAndInvalidMetadata(declared: Double?) {
            let ratio = CardImageLayout.aspect(declared)
            #expect(ratio.isFinite && ratio > 0)
            if declared == 2 {
                #expect(ratio == 2)
            }
        }
    }
#endif
