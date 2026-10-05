import Foundation
import Testing
@testable import DesignSystem

/// `EmojiCatalog`: the bundled list, its search and its skin tones
/// (reactions spec §4.3; slice 2 plan Task 1).
struct EmojiCatalogTests {
    private static let bundled = EmojiCatalog.bundled

    private static func entry(_ emoji: String) -> EmojiEntry? {
        bundled.categories.lazy.flatMap(\.entries).first { $0.emoji == emoji }
    }

    /// `emoji.json` missing or undecodable is a programming error, caught here
    /// against the real resource (spec §5).
    @Test func theBundledResourceLoadsInEmojiTestOrder() {
        #expect(Self.bundled.categories.count == 9)
        #expect(Self.bundled.categories.first?.name == "Smileys & Emotion")
        #expect(Self.bundled.categories.reduce(0) { $0 + $1.entries.count } > 1500)
    }

    @Test func aTonableEmojiTakesEachTone() throws {
        let thumbs = try #require(Self.entry("👍"))
        #expect(thumbs.tones?.count == 5)
        #expect(thumbs.emoji(in: .medium) == "👍🏽")
        #expect(thumbs.emoji(in: .dark) == "👍🏿")
        #expect(thumbs.emoji(in: .none) == "👍")
    }

    /// Review Focus 3: a tone is applied only where one exists.
    @Test func anEmojiWithoutTonesIgnoresTheTone() throws {
        let grin = try #require(Self.entry("😀"))
        #expect(grin.tones == nil)
        #expect(grin.emoji(in: .dark) == "😀")
    }

    /// Review Focus 4: names and keywords, in any case.
    @Test func searchFindsNamesAndKeywordsInAnyCase() {
        #expect(Self.bundled.search("thumbs").contains { $0.emoji == "👍" })
        #expect(Self.bundled.search("LIKE").contains { $0.emoji == "👍" })
        #expect(Self.bundled.search("  ").isEmpty)
        #expect(Self.bundled.search("").isEmpty)
    }

    @Test func searchIgnoresDiacritics() throws {
        let json = #"{"categories":[{"name":"Test","emoji":[{"e":"☕","n":"café au lait","k":["drink"]}]}]}"#
        let catalog = try EmojiCatalog.decode(Data(json.utf8))
        #expect(catalog.search("cafe").map(\.emoji) == ["☕"])
        #expect(catalog.search("CAFÉ").map(\.emoji) == ["☕"])
    }

    @Test func aCustomShortcodeMatchesItsWords() {
        #expect(EmojiCatalog.matches("parr", shortcode: ":party-parrot:"))
        #expect(EmojiCatalog.matches("PARTY", shortcode: ":party-parrot:"))
        #expect(!EmojiCatalog.matches("cat", shortcode: ":party-parrot:"))
    }
}
