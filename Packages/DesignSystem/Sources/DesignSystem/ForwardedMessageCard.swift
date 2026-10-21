import ChatKit
import SwiftUI

/// A received snapshot, with no actions against its source conversation.
struct ForwardedMessageCard: View {
    let forwarded: ForwardedMessage
    let directory: [Member.ID: Member]
    var me: Member.ID?
    var downloads: [String: AttachmentDownloadState] = [:]
    var loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)?
    var openAttachment: ((Attachment) async throws -> URL)?
    var loadRemoteImage: ((URL) async throws -> Data)?
    var attachmentFiles: AttachmentFileActions?

    @Environment(\.openURL) private var openURL

    private var senderDirectory: [Member.ID: Member] {
        var result = directory
        let id = forwarded.source.sender
        var sender = result[id] ?? Member(id: id, kind: .human)
        if let name = forwarded.senderName, !name.isEmpty {
            sender.displayName = name
        }
        if let url = forwarded.senderAvatarURL {
            sender.avatarURL = url
        }
        result[id] = sender
        return result
    }

    private var parts: AttachmentLayout.Parts {
        AttachmentLayout.parts(of: forwarded.message, canLoadImages: loadAttachment != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.right")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Forwarded message")
                Avatar(member: forwarded.source.sender, directory: senderDirectory, size: 20)
                Text(senderDirectory[forwarded.source.sender]?.displayName ?? "Unknown sender")
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
            }
            if forwarded.source.isDeleted {
                placeholder("Message deleted")
            } else {
                snapshot
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var snapshot: some View {
        if !forwarded.source.text.isEmpty {
            #if os(macOS)
                MessageTextView(
                    insets: .init(top: 0, left: 0, bottom: 0, right: 0),
                    message: forwarded.message, actions: nil, me: me,
                    open: { openURL($0) }
                )
            #else
                Text(forwarded.source.text).textSelection(.enabled)
            #endif
        }
        if let loadAttachment {
            ForEach(parts.images, id: \.id) { image in
                ViewThatFits(in: .horizontal) {
                    AttachmentImage(attachment: image, load: loadAttachment, open: openAttachment)
                    AttachmentChip(
                        attachment: image, state: downloads[image.id] ?? .idle, actions: attachmentFiles
                    )
                }
            }
        }
        ForEach(parts.files, id: \.id) { file in
            AttachmentChip(attachment: file, state: downloads[file.id] ?? .idle, actions: attachmentFiles)
        }
        ForEach(parts.previews, id: \.url) { link in
            ViewThatFits(in: .horizontal) {
                LinkPreviewCard(link: link, load: loadRemoteImage)
                Link(LinkCardLayout.title(for: link), destination: link.url)
                    .font(.callout).lineLimit(2)
            }
        }
        if forwarded.source.text.isEmpty, forwarded.attachments.isEmpty, parts.previews.isEmpty {
            placeholder("Forwarded a message")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout.italic()).foregroundStyle(.secondary)
    }
}
