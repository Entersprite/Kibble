import ChatKit
import SwiftUI
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The decisions behind a link card, pure so each is a test.
enum LinkCardLayout {
    static let width: CGFloat = AttachmentLayout.maxSide
    static let minImageHeight: CGFloat = 80
    static let maxImageHeight: CGFloat = 240
    static let fallbackImageHeight: CGFloat = 180

    /// An empty title - an image-only preview's - is no title.
    static func title(for link: MessageLink) -> String {
        let named = link.preview?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let named, !named.isEmpty {
            return named
        }
        return link.url.host() ?? link.url.absoluteString
    }

    /// A picture with no title, such as a GIF chosen from a picker, is drawn
    /// as the picture alone: a title row would only repeat the host. Without
    /// a loader the card keeps its title row, the host, so it can be clicked.
    static func isImageOnly(_ link: MessageLink) -> Bool {
        guard let preview = link.preview, preview.imageURL != nil else { return false }
        return preview.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `nil` without a preview: the title is already the host then, and a
    /// second line would only repeat it.
    static func domain(for link: MessageLink) -> String? {
        guard let preview = link.preview else { return nil }
        if let domain = preview.domain {
            return domain
        }
        let host = link.url.host() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The declared aspect at `width`, clamped; `nil` when unknown.
    static func imageHeight(width: CGFloat, pixelWidth: Int?, pixelHeight: Int?) -> CGFloat? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let height = (width * CGFloat(pixelHeight) / CGFloat(pixelWidth)).rounded()
        return min(maxImageHeight, max(minImageHeight, height))
    }
}

/// A Messages-style link card (links spec §7.3): the image full width, then
/// the title and the domain; an image-only preview is the image alone
/// (`LinkCardLayout.isImageOnly`). The image plays when it animates, as an
/// upload does (`PictureImage`). A click opens the link through `LinkPolicy`
/// (installed over the transcript); the full URL shows on hover.
struct LinkPreviewCard: View {
    let link: MessageLink
    let load: ((URL) async throws -> Data)?
    @Environment(\.openURL) private var openURL
    @Environment(\.openEmbeddedMedia) private var openMedia

    var body: some View {
        Button {
            if let player = link.preview?.playbackURL, let openMedia {
                openMedia(player)
            } else {
                openURL(link.url)
            }
        } label: {
            if let load, let imageURL = link.preview?.imageURL, LinkCardLayout.isImageOnly(link) {
                pictureAlone(imageURL, load: load)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    picture
                    VStack(alignment: .leading, spacing: 2) {
                        Label(LinkCardLayout.title(for: link), systemImage: symbol)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let domain = LinkCardLayout.domain(for: link) {
                            Text(domain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(width: LinkCardLayout.width, alignment: .leading)
                .background(.quinary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .buttonStyle(.plain)
        .help(link.url.absoluteString)
        .accessibilityAddTraits(.isLink)
    }

    /// Sized as an uploaded picture is, from the declared pixels, so a GIF
    /// is neither cropped nor moved when its bytes arrive; it stays a quiet
    /// placeholder while loading or after a failure.
    private func pictureAlone(_ url: URL, load: @escaping (URL) async throws -> Data) -> some View {
        let size = AttachmentLayout.displaySize(
            width: link.preview?.imageWidth,
            height: link.preview?.imageHeight
        )
        return RemoteImageView(url: url, load: load, animates: true) { phase in
            if case let .loaded(picture) = phase {
                PictureImage(picture: picture, label: Text(LinkCardLayout.title(for: link)))
                    .scaledToFit()
            } else {
                Rectangle().fill(.quinary)
                    .accessibilityLabel(LinkCardLayout.title(for: link))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: AttachmentLayout.cornerRadius))
    }

    private var symbol: String {
        switch link.preview?.presentation {
        case "video": "play.rectangle"
        case "document": "doc.text"
        default: "link"
        }
    }

    @ViewBuilder private var picture: some View {
        if let load, let imageURL = link.preview?.imageURL {
            let declared = LinkCardLayout.imageHeight(
                width: LinkCardLayout.width,
                pixelWidth: link.preview?.imageWidth,
                pixelHeight: link.preview?.imageHeight
            ) ?? LinkCardLayout.fallbackImageHeight
            RemoteImageView(url: imageURL, load: load, animates: true) { phase in
                switch phase {
                case .loading:
                    Rectangle().fill(.quaternary).frame(height: declared)
                case let .loaded(picture):
                    PictureImage(picture: picture, label: Text(LinkCardLayout.title(for: link)))
                        .scaledToFill()
                        .frame(
                            width: LinkCardLayout.width,
                            height: declared
                        )
                        .clipped()
                case .failed:
                    Rectangle().fill(.quaternary).frame(height: declared)
                }
            }
        }
    }
}

/// Copy Link, on both platforms.
enum LinkPasteboard {
    static func copy(_ url: URL) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        #else
            UIPasteboard.general.url = url
        #endif
    }
}
