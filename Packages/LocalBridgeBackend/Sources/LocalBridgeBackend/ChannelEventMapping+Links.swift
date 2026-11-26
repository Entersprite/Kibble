import ChatKit
import Foundation
import GChatBridgeCore

extension ChannelEventMapping {
    /// A message's links (links spec §4.1): annotations whose metadata oneof
    /// is `url_metadata`, decided by the oneof as uploads are, not by
    /// `annotation.type`. The shapes are the proto's and the references'
    /// (purple `googlechat_events.c:660-690`); `findings.md` §60 is `[Verify]`
    /// until the owner's probe run.
    ///
    /// - **No web URL, no link.** `url.url` must be `http` or `https`; never
    ///   `redirect_url` or `gws_url`, which are Google's wrappers `[Verify]`.
    /// - **A span is kept only when it lies inside the text**, in UTF-16 units
    ///   with a positive length. Anything else is an unanchored link: a
    ///   preview of a URL the text does not show (purple: "likely a tenor gif").
    /// - **`should_not_render` drops the card.** It drops an unanchored link
    ///   entirely, since it then has nothing left to show or click.
    /// - **A picture alone is a card.** A preview with an `image_url` but no
    ///   title keeps the picture, and an unanchored link to an image file is
    ///   its own picture (`pictureFile(_:)`).
    static func links(_ annotations: [GChatBridgeCore.Annotation], text: String) -> [MessageLink] {
        let units = text.utf16.count
        let mapped: [MessageLink] = annotations.compactMap { annotation in
            guard case let .urlMetadata(metadata)? = annotation.metadata,
                  let url = webURL(metadata.url.url)
            else { return nil }
            let start = Int(annotation.startIndex)
            let length = Int(annotation.length)
            let anchored = annotation.hasStartIndex && annotation.hasLength && start >= 0 && length > 0
                && length <= units - start
            let hidden = metadata.hasShouldNotRender && metadata.shouldNotRender
            if !anchored, hidden {
                return nil
            }
            return MessageLink(
                url: url,
                start: anchored ? start : nil,
                length: anchored ? length : nil,
                preview: hidden ? nil : preview(metadata, ownPicture: anchored ? nil : pictureFile(url))
            )
        }
        return MessageLinkAddressMapping.addingAddresses(to: mapped, in: text)
    }

    /// An unanchored link's own URL when it names an image file, for Chat's
    /// GIF picker: a message with no text and one unanchored link (purple's
    /// "likely a tenor gif"; `findings.md` §60.1, seen once in §60.3). Whether
    /// that link carries an `image_url`, a title, or only the file's own URL
    /// is `[Verify]`; this covers the last, so the picture still draws.
    /// `https` only, as for `image_url`, and decided by the path alone: a page
    /// named like a GIF is not a picture, and nothing is fetched to find out.
    static func pictureFile(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              pictureExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    private static let pictureExtensions: Set = ["gif", "png", "jpg", "jpeg", "webp"]

    static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    /// A title, a picture or both; neither is no card. A picture without a
    /// title keeps an empty one, which a client draws as the picture alone.
    /// `ownPicture` stands in only when Google declared no `image_url`.
    private static func preview(_ metadata: UrlMetadata, ownPicture: URL?) -> LinkPreview? {
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let declared = URL(string: metadata.imageURL)
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        let image = declared ?? ownPicture
        guard !title.isEmpty || image != nil else { return nil }
        return LinkPreview(
            title: title,
            snippet: nonEmpty(metadata.snippet),
            imageURL: image,
            imageWidth: dimension(metadata.intImageWidth, metadata.imageWidth),
            imageHeight: dimension(metadata.intImageHeight, metadata.imageHeight),
            domain: nonEmpty(metadata.domain)
        )
    }

    /// The integer field, else the string one; zero or unparseable is unknown.
    private static func dimension(_ number: Int32, _ text: String) -> Int? {
        if number > 0 {
            return Int(number)
        }
        return Int(text).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
