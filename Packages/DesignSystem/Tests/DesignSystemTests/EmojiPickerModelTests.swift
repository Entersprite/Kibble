import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The picker's decisions, pure (reactions spec §4.3; slice 2 plan Task 4),
/// and the quick row's (§4.2).
struct EmojiPickerModelTests {
    private static let catalog: EmojiCatalog = {
        let json = """
        {"categories":[
          {"name":"Smileys & Emotion","emoji":[{"e":"😀","n":"grinning face","k":["smile"]}]},
          {"name":"People & Body","emoji":[{"e":"👍","n":"thumbs up","k":["like"],
            "t":["👍🏻","👍🏼","👍🏽","👍🏾","👍🏿"]}]},
          {"name":"Empty","emoji":[]}
        ]}
        """
        return (try? EmojiCatalog.decode(Data(json.utf8))) ?? EmojiCatalog(categories: [])
    }()

    private static let parrot = CustomEmojiRef(id: "e-1", shortcode: ":party-parrot:", imageToken: "t")

    private static func model(
        query: String = "", tone: SkinTone = .none, recents: [ReactionChoice] = [],
        custom: [CustomEmojiRef] = [], reactions: [Reaction] = []
    ) -> EmojiPickerModel {
        EmojiPickerModel(
            catalog: catalog, recents: recents, custom: custom, reactions: reactions, tone: tone, query: query
        )
    }

    @Test func sectionsAreRecentThenCategoriesThenCustomWithEmptyOnesLeftOut() {
        let sections = Self.model(recents: [ReactionChoice(emoji: "🎉")], custom: [Self.parrot]).sections
        #expect(sections.map(\.title) == ["Recent", "Smileys & Emotion", "People & Body", "Custom"])
        #expect(Self.model().sections.map(\.title) == ["Smileys & Emotion", "People & Body"])
    }

    /// Review Focus 3: the tone reaches a toned entry's choice, nothing else.
    @Test func theToneIsAppliedToTonableEntriesOnly() {
        let sections = Self.model(tone: .dark, recents: [ReactionChoice(emoji: "👍")]).sections
        let people = sections.first { $0.title == "People & Body" }
        #expect(people?.items.map(\.choice.emoji) == ["👍🏿"])
        #expect(sections.first { $0.title == "Smileys & Emotion" }?.items.map(\.choice.emoji) == ["😀"])
        #expect(sections.first?.items.map(\.choice.emoji) == ["👍"])
    }

    /// Review Focus 4: a query gives one flat list, custom shortcodes
    /// included, and Return picks its first.
    @Test func aQueryGivesResultsAndAFirstResult() {
        let liked = Self.model(query: "like")
        #expect(liked.sections.map(\.title) == ["Results"])
        #expect(liked.firstResult?.choice.emoji == "👍")
        let parrot = Self.model(query: "parrot", custom: [Self.parrot])
        #expect(parrot.firstResult?.choice.customEmoji == Self.parrot)
        #expect(Self.model(query: "zzz").firstResult == nil)
        #expect(Self.model().firstResult == nil)
    }

    /// Review Focus 5: choosing one already mine removes it.
    @Test func choosingAReactionAlreadyMineRemovesIt() throws {
        let mine = [Reaction(emoji: "😀", count: 1, includesMe: true)]
        let model = Self.model(reactions: mine)
        let grin = try #require(model.sections.first?.items.first)
        #expect(!model.adds(grin))
        let thumbs = try #require(model.sections.last?.items.first)
        #expect(model.adds(thumbs))
    }

    @Test func theQuickRowIsRecentsFirstPaddedWithTheDefaults() {
        let recents = [
            ReactionChoice(emoji: "🦄"),
            ReactionChoice(customEmoji: Self.parrot),
            ReactionChoice(emoji: "👍")
        ]
        let items = QuickReactionItems.items(for: [], recents: recents)
        #expect(items.map(\.emoji) == ["🦄", "👍", "❤️", "😂", "😮", "😢"])
    }

    // `CLAUDE.md`: an SF Symbol name is an unchecked string.
    #if os(macOS)
        @Test func theAddReactionSymbolExists() {
            #expect(NSImage(systemSymbolName: EmojiPickerModel.addSymbol, accessibilityDescription: nil) !=
                nil)
        }
    #endif
}

#if os(macOS)
    import AppKit
#endif
