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

    static func title(for link: MessageLink) -> String {
        link.preview?.title ?? link.url.host() ?? link.url.absoluteString
    }

    static func domain(for link: MessageLink) -> String {
        if let domain = link.preview?.domain {
            return domain
        }
        let host = link.url.host() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The declared aspect at `width`, clamped; `nil` when unknown, which
    /// draws no reserved space before the bytes arrive.
    static func imageHeight(width: CGFloat, pixelWidth: Int?, pixelHeight: Int?) -> CGFloat? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let height = (width * CGFloat(pixelHeight) / CGFloat(pixelWidth)).rounded()
        return min(maxImageHeight, max(minImageHeight, height))
    }
}

/// A Messages-style link card (links spec §7.3): the image full width, then
/// the title and the domain. A click opens the link through `LinkPolicy`
/// (installed over the transcript); the full URL shows on hover.
struct LinkPreviewCard: View {
    let link: MessageLink
    let load: ((URL) async throws -> Data)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(link.url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                picture
                VStack(alignment: .leading, spacing: 2) {
                    Text(LinkCardLayout.title(for: link))
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(LinkCardLayout.domain(for: link))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: LinkCardLayout.width, alignment: .leading)
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help(link.url.absoluteString)
        .accessibilityAddTraits(.isLink)
    }

    @ViewBuilder private var picture: some View {
        if let load, let imageURL = link.preview?.imageURL {
            let declared = LinkCardLayout.imageHeight(
                width: LinkCardLayout.width,
                pixelWidth: link.preview?.imageWidth,
                pixelHeight: link.preview?.imageHeight
            )
            RemoteImageView(url: imageURL, load: load) { phase in
                switch phase {
                case .loading:
                    if let declared {
                        Rectangle().fill(.quaternary).frame(height: declared)
                    }
                case let .loaded(image):
                    Image(image, scale: 1, label: Text(LinkCardLayout.title(for: link)))
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: LinkCardLayout.width,
                            height: declared ?? LinkCardLayout.imageHeight(
                                width: LinkCardLayout.width, pixelWidth: image.width,
                                pixelHeight: image.height
                            )
                        )
                        .clipped()
                case .failed:
                    EmptyView()
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
