import ChatKit
import SwiftUI

/// A received snapshot, with no actions against its source conversation.
/// Its text, files, pictures and link cards carry the row's menu
/// (`MessageMenuContext`), so a right-click anywhere on the card offers the
/// row's reactions and items, acting on the row's message.
struct ForwardedMessageCard: View {
    /// The card's corners. Declared as its `containerShape`, so a picture
    /// inside rounds concentrically with them (`ConcentricRectangle`).
    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 10

    let forwarded: ForwardedMessage
    let directory: [Member.ID: Member]
    var me: Member.ID?
    var downloads: [String: AttachmentDownloadState] = [:]
    var loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)?
    var openAttachment: ((Attachment) async throws -> URL)?
    var loadRemoteImage: ((URL) async throws -> Data)?
    var attachmentFiles: AttachmentFileActions?
    var menu: MessageMenuContext?
    var gallery: AttachmentGallery?
    var quickLook: ((Attachment) -> Void)?

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
        .padding(Self.padding)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).stroke(.quaternary))
        .containerShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var snapshot: some View {
        if !forwarded.source.text.isEmpty {
            #if os(macOS)
                MessageTextView(
                    insets: .init(top: 0, left: 0, bottom: 0, right: 0),
                    message: forwarded.message, actions: menu?.reactions, me: me,
                    onMore: menu?.onMore, own: menu?.own,
                    open: { openURL($0) }, menuMessage: menu?.message
                )
            #else
                Text(forwarded.source.text).textSelection(.enabled)
            #endif
        }
        if let loadAttachment {
            ForEach(parts.images, id: \.id) { image in
                ViewThatFits(in: .horizontal) {
                    AttachmentImage(
                        attachment: image, load: loadAttachment, open: openAttachment, gallery: gallery,
                        quickLook: quickLook, menu: menu, saveAs: attachmentFiles?.saveAs, nested: true
                    )
                    chip(image)
                }
            }
        }
        ForEach(parts.files, id: \.id) { file in
            chip(file)
        }
        ForEach(parts.previews, id: \.url) { link in
            ViewThatFits(in: .horizontal) {
                LinkPreviewCard(link: link, load: loadRemoteImage)
                Link(LinkCardLayout.title(for: link), destination: link.url)
                    .font(.callout).lineLimit(2)
            }
            .modifier(ReactionMenu(context: menu ?? .empty(forwarded.message), link: link.url))
        }
        if forwarded.source.text.isEmpty, forwarded.attachments.isEmpty, parts.previews.isEmpty {
            placeholder("Forwarded a message")
        }
    }

    private func chip(_ file: Attachment) -> some View {
        AttachmentChip(
            attachment: file, state: downloads[file.id] ?? .idle, actions: attachmentFiles, menu: menu,
            quickLook: quickLook
        )
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout.italic()).foregroundStyle(.secondary)
    }
}

extension Message {
    /// What a forward card draws: the received snapshot, or the addressed
    /// source of a forward that has none yet, so a forward never draws as an
    /// empty bubble.
    var forwardedSnapshot: ForwardedMessage? {
        content?.forwarded ?? content?.forwardSource.map { ForwardedMessage(source: $0) }
    }
}
