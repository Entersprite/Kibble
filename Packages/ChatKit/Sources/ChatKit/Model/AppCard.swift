import Foundation

/// A Chat app's card (links spec §3.2), reduced to what a client can draw
/// and honour: a header, sections of text, decorated rows, pictures,
/// dividers, and buttons that open a URL. Buttons that call back into the
/// app are never mapped, because the seam cannot honour them.
///
/// **An empty card is meaningful:** the bridge received a card and could map
/// nothing in it, and the view draws a note in its place.
public struct AppCard: Codable, Hashable, Sendable {
    public var header: Header?
    public var sections: [Section]

    public init(header: Header? = nil, sections: [Section] = []) {
        self.header = header
        self.sections = sections
    }

    public var isEmpty: Bool {
        header == nil && sections.isEmpty
    }

    public struct Header: Hashable, Sendable {
        public var title: RichText
        public var subtitle: RichText?
        /// `https` only.
        public var imageURL: URL?
        public var circularImage: Bool

        public init(
            title: RichText,
            subtitle: RichText? = nil,
            imageURL: URL? = nil,
            circularImage: Bool = false
        ) {
            self.title = title
            self.subtitle = subtitle
            self.imageURL = imageURL
            self.circularImage = circularImage
        }
    }

    public struct Section: Codable, Hashable, Sendable {
        public var header: RichText?
        public var widgets: [Widget]

        public init(header: RichText? = nil, widgets: [Widget]) {
            self.header = header
            self.widgets = widgets
        }
    }

    /// One row of a section. `{"type": …}` discriminated and hand-coded; an
    /// unknown type is kept verbatim and drawn as nothing.
    public enum Widget: Hashable, Sendable {
        case text(RichText)
        case decorated(Decorated)
        case image(Picture)
        case buttons([LinkButton])
        case divider
        case unknown(type: String, payload: JSONValue)
    }

    /// A labelled value: an optional top label, the content, an optional
    /// bottom label, an icon, and a link and button, either of which opens a
    /// URL.
    public struct Decorated: Codable, Hashable, Sendable {
        public var top: RichText?
        public var content: RichText
        public var bottom: RichText?
        public var iconURL: URL?
        public var link: URL?
        public var button: LinkButton?

        public init(
            top: RichText? = nil, content: RichText, bottom: RichText? = nil,
            iconURL: URL? = nil, link: URL? = nil, button: LinkButton? = nil
        ) {
            self.top = top
            self.content = content
            self.bottom = bottom
            self.iconURL = iconURL
            self.link = link
            self.button = button
        }
    }

    public struct Picture: Codable, Hashable, Sendable {
        public var url: URL
        /// Width over height, when the app gave one.
        public var aspectRatio: Double?
        public var altText: String?
        public var link: URL?

        public init(url: URL, aspectRatio: Double? = nil, altText: String? = nil, link: URL? = nil) {
            self.url = url
            self.aspectRatio = aspectRatio
            self.altText = altText
            self.link = link
        }
    }
}

/// A card button that opens a URL: the only kind this client draws.
public struct LinkButton: Codable, Hashable, Sendable {
    public var label: String
    public var url: URL

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }
}

// MARK: - Header coding

/// Hand-coded so `circularImage` is written only when `true`, and a missing
/// key reads as square.
extension AppCard.Header: Codable {
    enum CodingKeys: String, CodingKey {
        case title, subtitle, imageURL, circularImage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: container.decode(RichText.self, forKey: .title),
            subtitle: container.decodeIfPresent(RichText.self, forKey: .subtitle),
            imageURL: container.decodeIfPresent(URL.self, forKey: .imageURL),
            circularImage: container.decodeIfPresent(Bool.self, forKey: .circularImage) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        if circularImage {
            try container.encode(true, forKey: .circularImage)
        }
    }
}

// MARK: - Widget coding

extension AppCard.Widget: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, decorated, image, buttons
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = try .text(container.decode(RichText.self, forKey: .text))
        case "decorated": self = try .decorated(container.decode(AppCard.Decorated.self, forKey: .decorated))
        case "image": self = try .image(container.decode(AppCard.Picture.self, forKey: .image))
        case "buttons": self = try .buttons(container.decode([LinkButton].self, forKey: .buttons))
        case "divider": self = .divider
        default: self = try .unknown(type: type, payload: UnknownFrame.payload(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            try UnknownFrame.encode(type: type, payload: payload, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .decorated(decorated):
            try container.encode("decorated", forKey: .type)
            try container.encode(decorated, forKey: .decorated)
        case let .image(picture):
            try container.encode("image", forKey: .type)
            try container.encode(picture, forKey: .image)
        case let .buttons(buttons):
            try container.encode("buttons", forKey: .type)
            try container.encode(buttons, forKey: .buttons)
        case .divider:
            try container.encode("divider", forKey: .type)
        case .unknown:
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }
}
