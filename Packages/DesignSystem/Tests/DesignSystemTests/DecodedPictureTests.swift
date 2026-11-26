import CoreGraphics
import Foundation
import Testing
@testable import DesignSystem

/// One decision for every picture in a message - an upload, a link card's or
/// an app card's: the first frame always, the bytes again only when they
/// animate within `AnimatedPicture`'s limits, and never under Reduce Motion.
struct DecodedPictureTests {
    @Test func anAnimationKeepsItsBytesBesideTheFirstFrame() throws {
        let gif = try TestGIF.make(frames: 3, side: 32)
        let picture = try #require(DecodedPicture.decode(gif))
        #expect(picture.animation == gif)
        #expect(picture.first.width == 32)
    }

    @Test func aStillOrOversizedPictureKeepsOnlyItsFirstFrame() throws {
        let still = try #require(try DecodedPicture.decode(TestGIF.make(frames: 1, side: 32)))
        #expect(still.animation == nil, "a still GIF")
        let large = try #require(try DecodedPicture.decode(TestGIF.make(frames: 2, side: 1200)))
        #expect(large.animation == nil, "a frame too large to decode each time")
        #expect(large.first.width <= Int(AttachmentLayout.maxSide * 2), "drawn at bubble size")
    }

    @Test func aPictureThatMustNotAnimateKeepsNoBytes() throws {
        let gif = try TestGIF.make(frames: 3, side: 32)
        #expect(DecodedPicture.decode(gif, animates: false)?.animation == nil)
    }

    @Test func bytesThatAreNoPictureDecodeToNothing() {
        #expect(DecodedPicture.decode(Data("not an image".utf8)) == nil)
    }

    @Test func reduceMotionShowsTheFirstFrame() throws {
        let picture = try #require(try DecodedPicture.decode(TestGIF.make(frames: 3, side: 32)))
        #expect(PictureImage.animation(of: picture, reduceMotion: false) == picture.animation)
        #expect(PictureImage.animation(of: picture, reduceMotion: true) == nil)
    }
}
