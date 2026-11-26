import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// A message's picture as decoded off the main thread: its first frame at
/// bubble size, and its bytes again only when they animate
/// (`AnimatedPicture.animates(_:)`). The one decoding step for an upload, a
/// link card's picture and an app card's, so every one of them follows the
/// same limits.
struct DecodedPicture: Sendable {
    let first: CGImage
    /// `nil` for a still picture, one past `AnimatedPicture`'s limits, or
    /// one decoded with `animates: false`.
    let animation: Data?

    /// `animates: false` keeps no bytes, for a picture that is never played
    /// (an avatar), so a scrolling list holds only frames for it.
    static func decode(
        _ data: Data, maxPixel: Int = Int(AttachmentLayout.maxSide * 2), animates: Bool = true
    ) -> DecodedPicture? {
        guard let first = AttachmentLayout.decode(data, maxPixel: maxPixel) else { return nil }
        return DecodedPicture(
            first: first,
            animation: animates && AnimatedPicture.animates(data) ? data : nil
        )
    }
}

/// A `DecodedPicture`, resizable: playing when it animates, its first frame
/// when it does not or when Reduce Motion is on. `label` `nil` is decorative.
struct PictureImage: View {
    let picture: DecodedPicture
    var label: Text?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let animation = Self.animation(of: picture, reduceMotion: reduceMotion) {
            AnimatedPicture(data: animation, first: picture.first, label: label)
        } else {
            PictureFrame(image: picture.first, label: label)
        }
    }

    nonisolated static func animation(of picture: DecodedPicture, reduceMotion: Bool) -> Data? {
        reduceMotion ? nil : picture.animation
    }
}

/// One frame, labeled or decorative.
private struct PictureFrame: View {
    let image: CGImage
    let label: Text?

    var body: some View {
        if let label {
            Image(image, scale: 1, label: label).resizable()
        } else {
            Image(decorative: image, scale: 1).resizable()
        }
    }
}

/// A GIF that plays, a frame at a time, through ImageIO's own timing
/// (`CGAnimateImageDataWithBlock`), with the first frame shown until the
/// second arrives. Bounded: only a picture small enough that one decoded
/// frame stays a few megabytes animates (`animates(_:)`), at most one frame
/// is kept besides the one on screen, and playing stops when the row leaves
/// the screen, dropping the frame it reached so an offscreen row keeps only
/// its first. With Reduce Motion on, `PictureImage` shows the first frame
/// instead.
struct AnimatedPicture: View {
    let data: Data
    let first: CGImage
    var label: Text?
    @State private var frame: CGImage?

    /// About 4.7 MB per decoded frame at four bytes a pixel.
    nonisolated static let maxPixels = 1_228_800
    nonisolated static let maxBytes = 12 * 1024 * 1024
    nonisolated static let maxFrames = 600

    var body: some View {
        PictureFrame(image: frame ?? first, label: label)
            .task(id: data) { await play() }
    }

    /// Whether `data` is an animation worth playing: more than one frame,
    /// none too large to decode one at a time, and a file of bounded size.
    nonisolated static func animates(_ data: Data) -> Bool {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              type == UTType.gif.identifier || type == UTType.png.identifier || type == UTType.webP.identifier
        else { return false }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= maxFrames,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return width > 0 && height > 0 && width * height <= maxPixels
    }

    private func play() async {
        let (frames, continuation) = AsyncStream.makeStream(
            of: CGImage.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let stop = AnimationStop()
        continuation.onTermination = { _ in stop.set() }
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { _, image, shouldStop in
            if stop.isSet {
                shouldStop.pointee = true
            } else {
                continuation.yield(image)
            }
        }
        guard status == noErr else {
            continuation.finish()
            return
        }
        for await image in frames {
            frame = image
        }
        // Stopped: the next appearance plays again from the first frame.
        frame = nil
    }
}

/// Tells ImageIO's frame block, which runs on the main queue, that the view
/// stopped listening; set from the stream's termination, on any thread.
private final class AnimationStop: Sendable {
    private let stopped = Mutex(false)

    var isSet: Bool {
        stopped.withLock { $0 }
    }

    func set() {
        stopped.withLock { $0 = true }
    }
}
