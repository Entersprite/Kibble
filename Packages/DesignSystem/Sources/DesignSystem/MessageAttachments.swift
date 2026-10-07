import ChatKit
import CoreGraphics
import Foundation
import ImageIO
import QuickLook
import SwiftUI

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

    /// `canLoadImages` is whether the host supplied a loader. Without one an
    /// image is named rather than drawn, because nothing could fill it.
    static func parts(of message: Message, canLoadImages: Bool) -> Parts {
        let images = canLoadImages ? message.attachments.filter(drawsAsPicture) : []
        let files = message.attachments.filter { !canLoadImages || !drawsAsPicture($0) }
        let previews = previewLinks(message.links)
        let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasOther = !message.attachments.isEmpty || !previews.isEmpty || !message.cards.isEmpty
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

    /// Decodes at most `maxPixel` on the long side, so a 4000-pixel photo
    /// costs a bubble's worth of memory rather than its own.
    static func decode(_ data: Data, maxPixel: Int = 1024) -> CGImage? {
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
/// transcript does not jump when the bytes arrive, and from the decoded image
/// once it has: the decode applies the EXIF orientation, and a declared size
/// taken before rotation would otherwise crop a portrait photo `[Verify]`
/// against an iPhone upload. Clicking fetches the original and hands it to
/// Quick Look.
struct AttachmentImage: View {
    let attachment: Attachment
    let load: (Attachment, AttachmentSize) async throws -> Data
    let open: ((Attachment) async throws -> URL)?

    private enum Phase {
        case loading
        case loaded(CGImage)
        case failed
    }

    @State private var phase = Phase.loading
    @State private var attempt = 0
    @State private var previewURL: URL?
    @State private var opening = false
    @State private var openFailed = false

    private var size: CGSize {
        if case let .loaded(image) = phase {
            return AttachmentLayout.displaySize(width: image.width, height: image.height)
        }
        return AttachmentLayout.displaySize(width: attachment.width, height: attachment.height)
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .task(id: attempt) { await fetch() }
            .quickLookPreview($previewURL)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            placeholder { ProgressView().controlSize(.small) }
                .accessibilityLabel(AttachmentLayout.label(for: attachment))
        case let .loaded(image):
            loaded(image)
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

    @ViewBuilder private func loaded(_ image: CGImage) -> some View {
        let picture = Image(image, scale: 1, label: Text(AttachmentLayout.label(for: attachment)))
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .overlay {
                if opening {
                    ProgressView().controlSize(.small)
                } else if openFailed {
                    Label("Couldn't open", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                }
            }
        if let open {
            Button { Task { await present(open) } } label: { picture }
                .buttonStyle(.plain)
                .accessibilityLabel(AttachmentLayout.label(for: attachment))
                .accessibilityHint("Opens the full-size image")
        } else {
            picture
        }
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
            let decoded = await Task.detached(priority: .userInitiated) { AttachmentLayout.decode(data) }
                .value
            guard !Task.isCancelled else { return }
            phase = decoded.map(Phase.loaded) ?? .failed
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }

    private func present(_ open: (Attachment) async throws -> URL) async {
        guard !opening else { return }
        opening = true
        openFailed = false
        defer { opening = false }
        do {
            previewURL = try await open(attachment)
        } catch {
            openFailed = true
        }
    }
}
