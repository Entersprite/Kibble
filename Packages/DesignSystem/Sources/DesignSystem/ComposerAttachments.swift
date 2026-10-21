import ChatKit
import Foundation
import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
#if canImport(QuickLookThumbnailing)
    import QuickLookThumbnailing
#endif

/// One file staged in the composer, as the composer draws it.
public struct ComposerAttachment: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ready
        /// `fraction` is `nil` until the first progress report, which draws a
        /// spinner rather than an empty ring.
        case uploading(fraction: Double?)
        case failed
    }

    public var id: String
    public var name: String
    public var byteSize: Int
    public var isImage: Bool
    /// Where the thumbnail and Quick Look read the file from.
    public var file: URL
    public var state: State

    public init(id: String, name: String, byteSize: Int, isImage: Bool, file: URL, state: State = .ready) {
        self.id = id
        self.name = name
        self.byteSize = byteSize
        self.isImage = isImage
        self.file = file
        self.state = state
    }

    var isUploading: Bool {
        if case .uploading = state {
            true
        } else {
            false
        }
    }
}

/// What the composer can ask for about staged files: stage files chosen with
/// the +, dropped on the conversation or pasted, stage a pasted picture, and
/// remove one.
///
/// Supplied only when the backend can upload; with none there is no +, no
/// drop target and no pasting of files (`CLAUDE.md`: never draw a control
/// the seam cannot honour). The + opens the system's file importer itself,
/// as a sheet on the window, and hands what was chosen to `stage`.
@MainActor
public struct ComposerAttachmentActions {
    public var stage: ([URL]) -> Void
    public var remove: (String) -> Void
    /// A picture pasted as data rather than as a file, which the host writes
    /// to a file it owns before staging. `nil` pastes no pictures.
    public var stageImage: ((ComposerPastedImage) -> Void)?

    public init(
        stage: @escaping ([URL]) -> Void,
        remove: @escaping (String) -> Void,
        stageImage: ((ComposerPastedImage) -> Void)? = nil
    ) {
        self.stage = stage
        self.remove = remove
        self.stageImage = stageImage
    }
}

/// A picture from the pasteboard, as a file's bytes: a screenshot copied to
/// the clipboard, or an image copied out of Preview or a web page.
public struct ComposerPastedImage: Equatable, Sendable {
    public let data: Data
    /// PNG, JPEG or HEIC: the pasteboard's TIFF becomes PNG before it gets
    /// here, so the file sent is one every recipient can open.
    public let type: UTType

    public init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }
}

/// The staged files, in a row above the field. A click on one, or Space on
/// one with the keyboard there, opens it in Quick Look, where the arrow keys
/// step through the others.
struct ComposerAttachmentStrip: View {
    let attachments: [ComposerAttachment]
    let remove: (String) -> Void

    @State private var previewing: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentChip(
                        attachment: attachment,
                        preview: { previewing = attachment.file },
                        remove: { remove(attachment.id) }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .quickLookPreview($previewing, in: attachments.map(\.file))
    }
}

/// A thumbnail or a file icon, the name and size, and remove, progress or a
/// failure mark, depending on where its upload stands.
struct ComposerAttachmentChip: View {
    let attachment: ComposerAttachment
    let preview: () -> Void
    let remove: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: Thumbnail?

    static let side: CGFloat = 36

    /// Concentric with the field's corners (`Composer`'s `containerShape`),
    /// and never under 8 pt: at the inset the field holds a chip, true
    /// concentric corners come to a few points and the chips drew nearly
    /// square (rendered). Eight is the thumbnail's 4 plus the 4 pt it sits in
    /// from the chip's edge, so the thumbnail is concentric with the chip.
    static let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true)
    static let thumbnailRadius: CGFloat = 4

    /// A photo fills its square; a document's page or icon fits in it, so a
    /// tall page is not cut to its middle.
    struct Thumbnail: Equatable {
        let image: CGImage
        let fills: Bool
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: preview) {
                HStack(spacing: 8) {
                    thumbnailView
                        .frame(width: Self.side, height: Self.side)
                        .clipShape(RoundedRectangle(cornerRadius: Self.thumbnailRadius))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.name.isEmpty ? "Attachment" : attachment.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(attachment
                                .state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    .frame(maxWidth: 160, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Quick Look")
            .accessibilityHint("Shows a preview")
            trailing
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Self.shape)
        .accessibilityElement(children: .contain)
        .task(id: attachment.file) { await loadThumbnail() }
    }

    @ViewBuilder private var thumbnailView: some View {
        if let thumbnail {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: thumbnail.fills ? .fill : .fit)
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch attachment.state {
        case let .uploading(fraction):
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.circular)
            .controlSize(.small)
            .accessibilityLabel("Uploading")
        case .ready, .failed:
            Button(action: remove) {
                Label("Remove \(attachment.name)", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var detail: String {
        switch attachment.state {
        case .failed: "Not sent"
        case .ready, .uploading: ByteCountFormatter.string(
                fromByteCount: Int64(attachment.byteSize),
                countStyle: .file
            )
        }
    }

    /// A picture through the same ImageIO decode the transcript uses, off the
    /// main actor and at chip size, so a 4000-pixel photo costs a
    /// thumbnail's memory. Anything else through Quick Look, which draws a
    /// document's first page, or the file's icon when it has no preview.
    private func loadThumbnail() async {
        let file = attachment.file
        if attachment.isImage {
            let maxPixel = Int(Self.side * 2)
            let image = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe)
                else { return CGImage?.none }
                return AttachmentLayout.decode(data, maxPixel: maxPixel)
            }.value
            thumbnail = image.map { Thumbnail(image: $0, fills: true) }
        } else {
            thumbnail = await Self.quickLookThumbnail(of: file, side: Self.side, scale: displayScale)
                .map { Thumbnail(image: $0, fills: false) }
        }
    }

    /// `nil` when Quick Look has nothing, which keeps the generic symbol;
    /// even a file it cannot read gets its type's icon (measured).
    nonisolated static func quickLookThumbnail(
        of file: URL,
        side: CGFloat,
        scale: CGFloat
    ) async -> CGImage? {
        #if canImport(QuickLookThumbnailing)
            let request = QLThumbnailGenerator.Request(
                fileAt: file,
                size: CGSize(width: side, height: side),
                scale: scale,
                representationTypes: [.icon, .thumbnail]
            )
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        #else
            return nil
        #endif
    }
}
