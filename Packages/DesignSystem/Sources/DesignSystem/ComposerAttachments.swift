import ChatKit
import Foundation
import ImageIO
import SwiftUI

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
    /// Where a thumbnail can be read from, for an image.
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

/// What the composer can ask for about staged files: open a picker, stage
/// files dropped on the conversation, and remove one.
///
/// Supplied only when the backend can upload; with none there is no paperclip
/// and no drop target (`CLAUDE.md`: never draw a control the seam cannot
/// honour).
@MainActor
public struct ComposerAttachmentActions {
    public var choose: () -> Void
    public var stage: ([URL]) -> Void
    public var remove: (String) -> Void

    public init(
        choose: @escaping () -> Void,
        stage: @escaping ([URL]) -> Void,
        remove: @escaping (String) -> Void
    ) {
        self.choose = choose
        self.stage = stage
        self.remove = remove
    }
}

/// The staged files, in a row above the field.
struct ComposerAttachmentStrip: View {
    let attachments: [ComposerAttachment]
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentChip(attachment: attachment) { remove(attachment.id) }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

/// A thumbnail or a file icon, the name and size, and remove, progress or a
/// failure mark, depending on where its upload stands.
struct ComposerAttachmentChip: View {
    let attachment: ComposerAttachment
    let remove: () -> Void

    @State private var thumbnail: CGImage?

    static let side: CGFloat = 36

    var body: some View {
        HStack(spacing: 8) {
            preview
                .frame(width: Self.side, height: Self.side)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
            trailing
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .task(id: attachment.file) { await loadThumbnail() }
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .scaledToFill()
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

    /// Off the main actor, at chip size, through the same ImageIO decode the
    /// transcript uses, so a 4000-pixel photo costs a thumbnail's memory.
    private func loadThumbnail() async {
        guard attachment.isImage else { return }
        let file = attachment.file
        let maxPixel = Int(Self.side * 2)
        thumbnail = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            return AttachmentLayout.decode(data, maxPixel: maxPixel)
        }.value
    }
}
