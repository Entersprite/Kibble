import ChatKit
import CoreGraphics
import Foundation
import ImageIO
import QuickLook
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// The decisions behind a message's attachments, pure so each is a test.
enum AttachmentLayout {
    struct Parts: Equatable {
        /// Drawn as pictures, in order.
        var images: [Attachment]
        /// Drawn as a name, in order.
        var files: [Attachment]
        /// Whether the text bubble draws at all.
        var showsText: Bool
        /// Link cards, in wire order, one per URL (links spec §7.3).
        var previews: [MessageLink] = []
        /// App cards, in order; an empty one is drawn as a note.
        var cards: [AppCard] = []
    }

    /// The bubble's widest and tallest side, in points.
    static let maxSide: CGFloat = 320
    /// An image whose size nobody declared is drawn as this square until its
    /// bytes say otherwise.
    static let fallbackSide: CGFloat = 200
    /// Neither side ever drops below this, so a sliver stays clickable.
    static let minSide: CGFloat = 40
    /// A picture's corners in a bubble, the text bubble's own.
    static let cornerRadius: CGFloat = 14
    /// The least a picture nested in a card rounds a corner far from the
    /// card's own corners.
    static let nestedMinimumCorner: CGFloat = 6

    /// `canLoadImages` is whether the host supplied a loader. Without one an
    /// image is named rather than drawn, because nothing could fill it.
    static func parts(of message: Message, canLoadImages: Bool) -> Parts {
        let images = canLoadImages ? message.attachments.filter(drawsAsPicture) : []
        let files = message.attachments.filter { !canLoadImages || !drawsAsPicture($0) }
        let previews = previewLinks(message.links)
        let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasOther = !message.attachments.isEmpty || !previews.isEmpty || !message.cards.isEmpty ||
            message.forwardedSnapshot != nil
        return Parts(
            images: images, files: files, showsText: hasText || !hasOther,
            previews: previews, cards: message.cards
        )
    }

    /// A card for every link with a preview, and for every unanchored link
    /// even without one: an unanchored link has no other place to be seen or
    /// clicked (Review Focus 1). One per URL, first wins.
    static func previewLinks(_ links: [MessageLink]) -> [MessageLink] {
        var seen: Set<URL> = []
        return links.filter { link in
            (link.preview != nil || link.start == nil) && seen.insert(link.url).inserted
        }
    }

    /// Only the types ImageIO decodes. Any other `image/` type (SVG, an icon,
    /// a Photoshop file) would fail behind a Retry that could never succeed,
    /// so it is named instead.
    static func drawsAsPicture(_ attachment: Attachment) -> Bool {
        decodable.contains(attachment.contentType.lowercased())
    }

    private static let decodable: Set = [
        "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp",
        "image/heic", "image/heif", "image/tiff", "image/bmp"
    ]

    /// Aspect-fit inside `maxSide`, at most one point per pixel, never below
    /// `minSide`. Unknown or zero sizes are the fallback square.
    static func displaySize(width: Int?, height: Int?) -> CGSize {
        guard let width, let height, width > 0, height > 0 else {
            return CGSize(width: fallbackSide, height: fallbackSide)
        }
        let pixels = CGSize(width: width, height: height)
        let scale = min(1, maxSide / pixels.width, maxSide / pixels.height)
        return CGSize(
            width: max(minSide, (pixels.width * scale).rounded()),
            height: max(minSide, (pixels.height * scale).rounded())
        )
    }

    static func label(for attachment: Attachment) -> String {
        attachment.name.isEmpty ? "Attachment" : attachment.name
    }

    /// The largest bubble is 320 points, so 640 pixels covers a 2x display.
    /// Keeping a 1024-pixel bitmap for each visible photo spent more memory
    /// without adding detail in the transcript; Quick Look still opens the
    /// original attachment on demand.
    static func decode(_ data: Data, maxPixel: Int = Int(maxSide * 2)) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// One uploaded image inside a message.
///
/// Sized from the declared dimensions before anything loads, so the
/// transcript does not jump when the bytes arrive. Unknown dimensions keep a
/// fallback square; aspect-fit draws the decoded orientation without cropping
/// or resizing that slot. Clicking opens the original in Quick Look, paging
/// through the message's other pictures and downloaded files (the bubble's
/// `AttachmentGallery`); the picture can be dragged out, and its menu offers
/// Quick Look, Copy Image, Save Image As… and Share before the row's items.
/// An animated GIF plays (`AnimatedPicture`).
struct AttachmentImage: View {
    let attachment: Attachment
    let load: (Attachment, AttachmentSize) async throws -> Data
    let open: ((Attachment) async throws -> URL)?
    /// What the bubble's Quick Look is doing for this picture; `nil` draws
    /// no progress or failure over it.
    var gallery: AttachmentGallery?
    /// Opens the bubble's Quick Look at this picture; `nil` makes the
    /// picture not clickable.
    var quickLook: ((Attachment) -> Void)?
    /// The row's menu, which the picture's replaces (`AttachmentChip.menu`).
    var menu: MessageMenuContext?
    /// `AttachmentFileActions.saveAs`; `nil` offers no Save Image As….
    var saveAs: ((Attachment) -> Void)?
    /// Inside a card that declares its `containerShape` (a forwarded
    /// message): the corners follow the card's, concentric, instead of the
    /// bubble's 14 points.
    var nested = false

    private enum Phase {
        case loading
        /// The first frame, and the bytes again when they animate.
        case loaded(CGImage, animation: Data?)
        case failed
    }

    @State private var phase = Phase.loading
    @State private var attempt = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGSize {
        AttachmentLayout.displaySize(width: attachment.width, height: attachment.height)
    }

    private var label: Text {
        Text(AttachmentLayout.label(for: attachment))
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .task(id: attempt) { await fetch() }
    }

    private var shape: AnyShape {
        nested
            ?
            AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(AttachmentLayout
                    .nestedMinimumCorner))))
            : AnyShape(RoundedRectangle(cornerRadius: AttachmentLayout.cornerRadius))
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            placeholder { ProgressView().controlSize(.small) }
                .accessibilityLabel(AttachmentLayout.label(for: attachment))
        case let .loaded(image, animation):
            loaded(image, animation: reduceMotion ? nil : animation)
        case .failed:
            // The words when they fit, the button alone when they do not: a
            // 320x40 sliver has no room for both (`minSide`).
            placeholder {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 6) {
                        Label("Couldn't load image", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        retry.labelStyle(.titleOnly)
                    }
                    retry.labelStyle(.iconOnly)
                }
            }
        }
    }

    private var retry: some View {
        Button {
            phase = .loading
            attempt += 1
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
        .accessibilityLabel("Retry loading \(AttachmentLayout.label(for: attachment))")
    }

    @ViewBuilder private func loaded(_ image: CGImage, animation: Data?) -> some View {
        let picture = Group {
            if let animation {
                AnimatedPicture(data: animation, first: image, label: label)
            } else {
                Image(image, scale: 1, label: label).resizable()
            }
        }
        .scaledToFit()
        .frame(width: size.width, height: size.height)
        .overlay {
            if gallery?.opening.contains(attachment.id) == true {
                ProgressView().controlSize(.small)
            } else if gallery?.failed.contains(attachment.id) == true {
                Label("Couldn't open", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(6)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .contextMenu {
            MessageMenuContent(nestedIn: menu) { pictureItems(image) }
        }
        if let open, let quickLook {
            Button { quickLook(attachment) } label: { picture }
                .buttonStyle(.plain)
                .accessibilityLabel(AttachmentLayout.label(for: attachment))
                .accessibilityHint("Opens the full-size image")
                .draggable(transfer(open))
        } else {
            picture
        }
    }

    /// What the picture's own menu offers, before the row's items.
    @ViewBuilder private func pictureItems(_ image: CGImage) -> some View {
        if open != nil, let quickLook {
            Button("Quick Look", systemImage: MessageMenuSymbols.quickLook) { quickLook(attachment) }
        }
        Button("Copy Image", systemImage: MessageMenuSymbols.copyImage) { copy(image) }
        if let saveAs {
            Button("Save Image As…", systemImage: MessageMenuSymbols.saveAs) { saveAs(attachment) }
        }
        if let open {
            let transfer = transfer(open)
            ShareLink(
                item: transfer,
                preview: SharePreview(transfer.name, image: Image(image, scale: 1, label: label))
            )
        }
    }

    /// The original when the host has it; the picture on screen otherwise,
    /// or when the original cannot be had.
    private func copy(_ image: CGImage) {
        guard let open else {
            ImagePasteboard.copy(image)
            return
        }
        let attachment = attachment
        Task {
            if let file = try? await open(attachment) {
                ImagePasteboard.copy(fileAt: file)
            } else {
                ImagePasteboard.copy(image)
            }
        }
    }

    private func transfer(_ open: @escaping (Attachment) async throws -> URL) -> AttachmentTransfer {
        let attachment = attachment
        return AttachmentTransfer(attachment: attachment) { try await open(attachment) }
    }

    private func placeholder(@ViewBuilder _ inside: () -> some View) -> some View {
        Rectangle().fill(.quinary).overlay { inside() }
    }

    /// Runs on every appear, because `.task` does. A row scrolled back into
    /// view keeps its `@State`, and an image already drawn must not flash back
    /// to a spinner, or turn into a failure because the network went away
    /// since. Retry sets `.loading` itself before it bumps `attempt`.
    private func fetch() async {
        if case .loaded = phase {
            return
        }
        phase = .loading
        do {
            let data = try await load(attachment, .preview)
            let decoded = await Task.detached(priority: .userInitiated) {
                (AttachmentLayout.decode(data), AnimatedPicture.animates(data) ? data : nil)
            }.value
            guard !Task.isCancelled else { return }
            phase = decoded.0.map { Phase.loaded($0, animation: decoded.1) } ?? .failed
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }
}

/// A GIF that plays, a frame at a time, through ImageIO's own timing
/// (`CGAnimateImageDataWithBlock`), with the first frame shown until the
/// second arrives. Bounded: only a picture small enough that one decoded
/// frame stays a few megabytes animates (`animates(_:)`), at most one frame
/// is kept besides the one on screen, and playing stops when the row leaves
/// the screen. With Reduce Motion on, `AttachmentImage` shows the first frame
/// instead.
struct AnimatedPicture: View {
    let data: Data
    let first: CGImage
    let label: Text
    @State private var frame: CGImage?

    /// About 4.7 MB per decoded frame at four bytes a pixel.
    nonisolated static let maxPixels = 1_228_800
    nonisolated static let maxBytes = 12 * 1024 * 1024
    nonisolated static let maxFrames = 600

    var body: some View {
        Image(frame ?? first, scale: 1, label: label)
            .resizable()
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
