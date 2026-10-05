import ChatKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DesignSystem

struct ReactionDisplayTests {
    @Test func aReactionOfMineSaysSo() {
        let label = ReactionDisplay.accessibilityLabel(for: Reaction(emoji: "👍", count: 2, includesMe: true))
        #expect(label == "👍, 2, you reacted")
    }

    @Test func someoneElsesReactionIsTheEmojiAndTheCount() {
        #expect(ReactionDisplay.accessibilityLabel(for: Reaction(emoji: "🎉", count: 1)) == "🎉, 1")
    }

    @Test func aCustomEmojiIsReadByItsShortcode() {
        let parrot = Reaction(
            emoji: ":parrot:",
            count: 3,
            customEmoji: CustomEmojiRef(id: "e-1", shortcode: ":parrot:")
        )
        #expect(ReactionDisplay.accessibilityLabel(for: parrot) == ":parrot:, 3")
    }

    @Test func theQuickSetIsSixDistinctEmoji() {
        #expect(QuickReactions.defaults == ["👍", "❤️", "😂", "😮", "😢", "🎉"])
    }

    /// Review Focus 5: choosing one already mine removes it.
    @Test func aQuickEmojiAlreadyMineIsRemoved() {
        let mine = [Reaction(emoji: "👍", count: 2, includesMe: true)]
        #expect(!QuickReactions.adds(ReactionChoice(emoji: "👍"), to: mine))
        #expect(QuickReactions.adds(ReactionChoice(emoji: "🎉"), to: mine))
        #expect(QuickReactions.adds(ReactionChoice(emoji: "👍"), to: [Reaction(emoji: "👍", count: 2)]))
    }

    @Test func onlyACustomEmojiWithALoaderAsksForAnImage() {
        let ref = CustomEmojiRef(id: "e-1", shortcode: ":parrot:", imageToken: "t")
        let custom = Reaction(emoji: ref.displayText, count: 1, customEmoji: ref)
        #expect(ReactionDisplay.imageRequest(for: custom, canLoad: true) == ref)
        #expect(ReactionDisplay.imageRequest(for: custom, canLoad: false) == nil)
        #expect(ReactionDisplay.imageRequest(for: Reaction(emoji: "👍", count: 1), canLoad: true) == nil)
    }

    /// Review fix: a token arriving later changes the key, so a capsule on
    /// screen retries; the same reference keeps the same key.
    @Test func aTokenArrivingLaterChangesTheImageTaskKey() {
        let bare = CustomEmojiRef(id: "e-1", shortcode: ":parrot:")
        let tokened = CustomEmojiRef(id: "e-1", shortcode: ":parrot:", imageToken: "t")
        let before = Reaction(emoji: bare.displayText, count: 1, customEmoji: bare)
        let after = Reaction(emoji: tokened.displayText, count: 1, customEmoji: tokened)
        #expect(ReactionDisplay.imageTaskKey(for: before, canLoad: true)
            != ReactionDisplay.imageTaskKey(for: after, canLoad: true))
        #expect(ReactionDisplay.imageTaskKey(for: after, canLoad: true)
            == ReactionDisplay.imageTaskKey(for: after, canLoad: true))
    }

    /// Review Focus 5: bytes that are not an image leave the shortcode.
    @Test func undecodableBytesGiveNoImage() {
        #expect(ReactionDisplay.image(from: Data("<html>refused</html>".utf8)) == nil)
        #expect(ReactionDisplay.image(from: Data()) == nil)
    }

    @Test func aPNGDecodesAtCapsuleSize() throws {
        let image = try #require(ReactionDisplay.image(from: Self.png(side: 256)))
        #expect(max(image.width, image.height) <= 64)
    }

    /// A solid square, drawn here so no fixture file is needed.
    private static func png(side: Int) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
