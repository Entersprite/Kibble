import Foundation

/// Text in an app card: runs, in order, each with its own style and
/// optional link (links spec §3.2). Built from Google's formatted text by
/// the bridge, which keeps a run's link only for `http`, `https` or
/// `mailto`.
public struct RichText: Codable, Hashable, Sendable {
    public var runs: [Run]

    public init(runs: [Run]) {
        self.runs = runs
    }

    public init(_ plain: String) {
        runs = [Run(text: plain)]
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }

    public struct Run: Hashable, Sendable {
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var strikethrough: Bool
        public var link: URL?

        public init(
            text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
            strikethrough: Bool = false, link: URL? = nil
        ) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.strikethrough = strikethrough
            self.link = link
        }
    }
}

// MARK: - Run coding

/// Hand-coded so a `false` flag is never written: a run is almost always
/// plain, and a missing key reads as `false`.
extension RichText.Run: Codable {
    enum CodingKeys: String, CodingKey {
        case text, bold, italic, underline, strikethrough, link
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? false
        }
        try self.init(
            text: container.decode(String.self, forKey: .text),
            bold: flag(.bold), italic: flag(.italic), underline: flag(.underline),
            strikethrough: flag(.strikethrough),
            link: container.decodeIfPresent(URL.self, forKey: .link)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        let flags: [(Bool, CodingKeys)] = [
            (bold, .bold), (italic, .italic), (underline, .underline), (strikethrough, .strikethrough)
        ]
        for (isSet, key) in flags where isSet {
            try container.encode(true, forKey: key)
        }
        try container.encodeIfPresent(link, forKey: .link)
    }
}
