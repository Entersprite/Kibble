import Foundation

/// A link in a message (links spec §3.1): where it goes, where it sits in
/// `text` when it sits anywhere, and the preview Google attached, if any.
///
/// Coding is synthesised: every optional is omitted when `nil`, which is what
/// keeps an unanchored link's frame free of `start` and `length`.
public struct MessageLink: Codable, Hashable, Sendable {
    /// `http` or `https`; the bridge maps nothing else.
    public var url: URL

    /// The span in `text`, in UTF-16 code units as for `Mention`; `nil` for a
    /// link with no place in the text (a preview of a URL the text does not
    /// contain). A client must still check a span before drawing it.
    public var start: Int?

    /// See `start`.
    public var length: Int?

    /// `nil`: no card, because Google sent none or the sender hid it.
    public var preview: LinkPreview?
    /// An internal source identified by the provider. A URL and address grant
    /// no access; the client must resolve it in the current account.
    public var messageAddress: MessageAddress?

    public init(
        url: URL, start: Int? = nil, length: Int? = nil, preview: LinkPreview? = nil,
        messageAddress: MessageAddress? = nil
    ) {
        self.url = url
        self.start = start
        self.length = length
        self.preview = preview
        self.messageAddress = messageAddress
    }
}

/// What Google says a link is, for a card (links spec §3.1). Never fetched
/// by this client from the linked site (owner's decision).
public struct LinkPreview: Codable, Hashable, Sendable {
    /// Empty for a picture-only preview (an `imageURL` and no text), which a
    /// client draws as the picture alone.
    public var title: String
    public var snippet: String?

    /// `https` only. Fetched through `ChatBackend.remoteImage(_:)`.
    public var imageURL: URL?

    /// Pixels, as declared. `nil` is unknown, never zero.
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var domain: String?
    public var presentation: String?
    /// An optional player opened explicitly through the native host.
    public var playbackURL: URL?

    public init(
        title: String,
        snippet: String? = nil,
        imageURL: URL? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        domain: String? = nil,
        presentation: String? = nil,
        playbackURL: URL? = nil
    ) {
        self.title = title
        self.snippet = snippet
        self.imageURL = imageURL
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.domain = domain
        self.presentation = presentation
        self.playbackURL = playbackURL
    }
}
