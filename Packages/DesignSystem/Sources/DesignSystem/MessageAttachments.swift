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
        let images = canLoadImages ? message.attachments.filter(\.isImage) : []
        let files = message.attachments.filter { !canLoadImages || !$0.isImage }
        let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Parts(images: images, files: files, showsText: hasText || message.attachments.isEmpty)
    }

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
/// transcript does not jump when the bytes arrive; re-sized from the decoded
/// image only when nothing was declared. Clicking fetches the original and
/// hands it to Quick Look.
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
        if case let .loaded(image) = phase, attachment.width == nil || attachment.height == nil {
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
        case let .loaded(image):
            loaded(image)
        case .failed:
            placeholder {
                VStack(spacing: 6) {
                    Label("Couldn't load image", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { attempt += 1 }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func loaded(_ image: CGImage) -> some View {
        let picture = Image(decorative: image, scale: 1)
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
            picture.accessibilityLabel(AttachmentLayout.label(for: attachment))
        }
    }

    private func placeholder(@ViewBuilder _ inside: () -> some View) -> some View {
        Rectangle().fill(.quinary).overlay { inside() }
            .accessibilityLabel(AttachmentLayout.label(for: attachment))
    }

    private func fetch() async {
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

/// A non-image upload, or an image with no loader: its name, and nothing to
/// click, because nothing here can download a file yet.
struct AttachmentChip: View {
    let attachment: Attachment

    var body: some View {
        Label(AttachmentLayout.label(for: attachment), systemImage: "paperclip")
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }
}
