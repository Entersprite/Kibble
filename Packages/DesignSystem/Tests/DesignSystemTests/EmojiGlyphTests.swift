import CoreGraphics
import Testing
@testable import DesignSystem

/// `EmojiGlyph`: the context menu's palette draws a cell's image and ignores
/// its title, so each quick emoji must exist as a picture with something in it.
@MainActor
struct EmojiGlyphTests {
    @Test(arguments: QuickReactions.defaults)
    func aQuickEmojiDrawsAsAColouredPicture(_ emoji: String) throws {
        let image = try #require(EmojiGlyph.image(for: emoji))
        #expect(image.width == 40)
        #expect(image.height == 40)
        #expect(Self.colouredPixels(in: image) > 0, "\(emoji) drew nothing but grey or clear pixels")
    }

    /// The control: plain text draws grey, so the check above can fail, and
    /// would for an emoji the font has no glyph for.
    @Test func plainTextIsNotColoured() throws {
        let image = try #require(EmojiGlyph.image(for: "x"))
        #expect(Self.colouredPixels(in: image) == 0)
    }

    @Test func aSecondRequestIsTheSamePicture() throws {
        let first = try #require(EmojiGlyph.image(for: "👍"))
        let second = try #require(EmojiGlyph.image(for: "👍"))
        #expect(first === second)
    }

    /// Pixels that are visible and not grey: an emoji glyph is coloured, and a
    /// missing glyph, a tofu box or an empty frame is not.
    private static func colouredPixels(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        return stride(from: 0, to: bytes.count, by: 4).count { offset in
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
            let alpha = Int(bytes[offset + 3])
            return alpha > 32 && max(red, green, blue) - min(red, green, blue) > 40
        }
    }
}
