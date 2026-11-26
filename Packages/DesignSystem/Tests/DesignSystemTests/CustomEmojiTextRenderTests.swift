#if os(macOS)
    import AppKit
    import ChatKit
    import Testing
    @testable import DesignSystem

    @MainActor
    struct CustomEmojiTextRenderTests {
        @Test func imageArrivalReplacesTheFallbackAndCacheSeparatesImageBytes() throws {
            let emoji = CustomEmojiRef(id: "emoji", shortcode: "parrot", imageToken: "token")
            let message = Message(
                id: .init("message"),
                conversationID: .init("chat"),
                threadID: .init("thread"),
                sender: .init("person"),
                text: "a " + emoji.displayText + " z",
                createdAt: Date(),
                content: MessageContent(customEmoji: [MessageCustomEmoji(
                    emoji: emoji,
                    start: 2,
                    length: emoji
                        .displayText.utf16
                        .count
                )])
            )
            let bytes = try imageData()
            let cache = MessageTextCache()
            let fallback = cache.attributed(message: message, me: nil, inOwnBubble: false)
            #expect(fallback.string == message.text)
            let image = cache.attributed(
                message: message,
                me: nil,
                inOwnBubble: false,
                emojiImages: [emoji: bytes]
            )
            #expect(image.string == "a \u{FFFC} z")
            let attachment = try #require(image.attribute(
                .attachment,
                at: 2,
                effectiveRange: nil
            ) as? NSTextAttachment)
            #expect(attachment.attachmentCell != nil)
            #expect(!(image is NSMutableAttributedString))
            #expect(cache.attributed(message: message, me: nil, inOwnBubble: false) === fallback)
            #expect(cache.misses == 2)
            #expect(try paintedRedPixels(in: image) > 20)
        }

        private func imageData() throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            for column in 0 ..< 2 {
                for row in 0 ..< 2 {
                    bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: column, y: row)
                }
            }
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }

        private func paintedRedPixels(in image: NSAttributedString) throws -> Int {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let view = BubbleTextView.make()
            view.insets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
            window.contentView = view
            view.show(image)
            view.layoutSubtreeIfNeeded()
            let rendered = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rendered)
            var redPixels = 0
            for column in 0 ..< rendered.pixelsWide {
                for row in 0 ..< rendered.pixelsHigh {
                    if let pixel = rendered.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB),
                       pixel.alphaComponent > 0.5, pixel.redComponent > 0.7, pixel.greenComponent < 0.4 {
                        redPixels += 1
                    }
                }
            }
            window.close()
            return redPixels
        }
    }
#endif
