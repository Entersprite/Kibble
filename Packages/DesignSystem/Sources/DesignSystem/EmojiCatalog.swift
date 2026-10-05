import Foundation

/// One of the five Fitzpatrick modifiers, or none: one app-wide setting
/// (reactions spec §3), applied to what the picker shows and picks.
public enum SkinTone: Int, CaseIterable, Sendable {
    case none, light, mediumLight, medium, mediumDark, dark
}

/// One emoji the picker can show: the base form, its CLDR name and keywords,
/// and its five toned forms when it takes a tone.
struct EmojiEntry: Hashable, Sendable {
    let emoji: String
    let name: String
    let keywords: [String]
    /// Light to dark, five long, or `nil` for an emoji that takes no tone.
    let tones: [String]?

    /// The base form for `.none`, and for an emoji that takes no tone.
    func emoji(in tone: SkinTone) -> String {
        guard tone != .none, let tones, tones.count == 5 else { return emoji }
        return tones[tone.rawValue - 1]
    }
}

struct EmojiCategory: Hashable, Sendable {
    let name: String
    let entries: [EmojiEntry]
}

/// The emoji the picker offers, from the committed `emoji.json` (reactions
/// spec §4.3): fully-qualified emoji in Unicode's `emoji-test.txt` order and
/// groups, named and keyworded by CLDR, filtered to what this Mac's emoji font
/// draws. `scripts/generate-emoji.sh` regenerates it at pinned versions.
struct EmojiCatalog: Sendable {
    let categories: [EmojiCategory]

    /// The bundled list. A missing or undecodable resource is a programming
    /// error, which `EmojiCatalogTests` catches against the real file; in the
    /// app it degrades to an empty picker rather than a crash.
    static let bundled: EmojiCatalog = {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data)
        else { return EmojiCatalog(categories: []) }
        return catalog
    }()

    static func decode(_ data: Data) throws -> EmojiCatalog {
        let file = try JSONDecoder().decode(EmojiFile.self, from: data)
        return EmojiCatalog(categories: file.categories.map { category in
            EmojiCategory(name: category.name, entries: category.emoji.map {
                EmojiEntry(emoji: $0.emoji, name: $0.name, keywords: $0.keywords, tones: $0.tones)
            })
        })
    }

    /// Case- and diacritic-insensitive. Names containing the query come
    /// first, then keywords that start with it, each in catalog order. An
    /// empty query finds nothing: the picker shows its sections instead.
    func search(_ query: String) -> [EmojiEntry] {
        let needle = Self.folded(query)
        guard !needle.isEmpty else { return [] }
        let all = categories.flatMap(\.entries)
        let byName = all.filter { Self.folded($0.name).contains(needle) }
        let named = Set(byName)
        let byKeyword = all.filter { entry in
            !named.contains(entry) && entry.keywords.contains { Self.folded($0).hasPrefix(needle) }
        }
        return byName + byKeyword
    }

    /// A custom emoji's shortcode, colons and all, against the same folding.
    static func matches(_ query: String, shortcode: String) -> Bool {
        let needle = folded(query)
        return !needle.isEmpty && folded(shortcode).contains(needle)
    }

    private static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// `emoji.json`'s shape. The one-letter keys keep a 1900-entry file small;
/// `CodingKeys` spells them out so the Swift names stay readable.
private struct EmojiFile: Decodable {
    let categories: [EmojiFileCategory]
}

private struct EmojiFileCategory: Decodable {
    let name: String
    let emoji: [EmojiFileEntry]
}

private struct EmojiFileEntry: Decodable {
    let emoji: String
    let name: String
    let keywords: [String]
    let tones: [String]?

    enum CodingKeys: String, CodingKey {
        case emoji = "e", name = "n", keywords = "k", tones = "t"
    }
}
