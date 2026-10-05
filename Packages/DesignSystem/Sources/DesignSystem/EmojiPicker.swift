import ChatKit
import SwiftUI

/// One cell of the picker: what it draws, what choosing it reacts with.
struct EmojiPickerItem: Hashable, Identifiable {
    let choice: ReactionChoice
    /// For VoiceOver and the hover tooltip: the CLDR name, or the shortcode.
    let name: String

    var id: String {
        choice.key
    }
}

struct EmojiPickerSection: Hashable, Identifiable {
    let title: String
    let items: [EmojiPickerItem]

    var id: String {
        title
    }
}

/// The picker's decisions, pure so each is a test (reactions spec §4.3):
/// Recent, then the Unicode categories, then Custom, with empty ones left
/// out; one flat "Results" list for a query; the skin tone applied to entries
/// that take one; and the same add-or-remove rule as both menus.
struct EmojiPickerModel {
    /// `face.smiling`, verified by `EmojiPickerModelTests` (`CLAUDE.md`: an
    /// SF Symbol name is an unchecked string).
    static let addSymbol = "face.smiling"

    let catalog: EmojiCatalog
    let recents: [ReactionChoice]
    let custom: [CustomEmojiRef]
    let reactions: [Reaction]
    let tone: SkinTone
    let query: String

    var sections: [EmojiPickerSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else {
            let results = catalog.search(trimmed).map(item(for:))
                + custom.filter { EmojiCatalog.matches(trimmed, shortcode: $0.shortcode) }.map(item(for:))
            return results.isEmpty ? [] : [EmojiPickerSection(title: "Results", items: results)]
        }
        var sections: [EmojiPickerSection] = []
        if !recents.isEmpty {
            sections.append(EmojiPickerSection(title: "Recent", items: recents.map(item(for:))))
        }
        for category in catalog.categories where !category.entries.isEmpty {
            sections.append(EmojiPickerSection(title: category.name, items: category.entries.map(item(for:))))
        }
        if !custom.isEmpty {
            sections.append(EmojiPickerSection(title: "Custom", items: custom.map(item(for:))))
        }
        return sections
    }

    /// What Return chooses: the first result of a query, and nothing without one.
    var firstResult: EmojiPickerItem? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return sections.first?.items.first
    }

    func adds(_ item: EmojiPickerItem) -> Bool {
        QuickReactions.adds(item.choice, to: reactions)
    }

    private func item(for entry: EmojiEntry) -> EmojiPickerItem {
        EmojiPickerItem(choice: ReactionChoice(emoji: entry.emoji(in: tone)), name: entry.name)
    }

    private func item(for emoji: CustomEmojiRef) -> EmojiPickerItem {
        EmojiPickerItem(choice: ReactionChoice(customEmoji: emoji), name: emoji.displayText)
    }

    /// A recent is shown as it was picked, tone and all.
    private func item(for choice: ReactionChoice) -> EmojiPickerItem {
        EmojiPickerItem(choice: choice, name: choice.customEmoji?.displayText ?? choice.emoji)
    }
}

/// The full picker (reactions spec §4.3), in a popover: a search field focused
/// on open, a skin-tone control, and the sections as a grid. Choosing calls
/// back with the choice and whether it adds, and the host closes the popover.
/// Return chooses the first result; arrow keys through the grid are deferred
/// (slice 2 plan, ruling 3).
struct EmojiPicker: View {
    let reactions: [Reaction]
    let actions: ReactionActions
    let onChoose: (ReactionChoice, Bool) -> Void

    @State private var query = ""
    @State private var tone: SkinTone
    @State private var recents: [ReactionChoice] = []
    @State private var custom: [CustomEmojiRef] = []
    @FocusState private var searchFocused: Bool

    init(
        reactions: [Reaction],
        actions: ReactionActions,
        onChoose: @escaping (ReactionChoice, Bool) -> Void
    ) {
        self.reactions = reactions
        self.actions = actions
        self.onChoose = onChoose
        _tone = State(initialValue: actions.skinTone)
    }

    private var model: EmojiPickerModel {
        EmojiPickerModel(
            catalog: .bundled, recents: recents, custom: custom, reactions: reactions, tone: tone,
            query: query
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search Emoji", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = model.firstResult {
                            choose(first)
                        }
                    }
                Picker("Skin Tone", selection: $tone) {
                    ForEach(SkinTone.allCases, id: \.self) { tone in
                        Text(Self.toneSample(tone)).tag(tone)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: tone) { _, new in actions.setSkinTone(new) }
            }
            .padding(8)
            Divider()
            grid
        }
        .frame(width: 340, height: 380)
        .onAppear {
            recents = actions.recents()
            custom = actions.customCatalog()
            searchFocused = true
        }
    }

    private var grid: some View {
        ScrollView {
            let sections = model.sections
            if sections.isEmpty {
                Text("No emoji found")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            }
            EmojiPickerGrid(sections: sections, loadImage: actions.customImage, onChoose: choose)
                .padding(8)
        }
    }

    private func choose(_ item: EmojiPickerItem) {
        onChoose(item.choice, model.adds(item))
    }

    /// A raised hand in each tone: the control's own picture of the choice.
    static func toneSample(_ tone: SkinTone) -> String {
        EmojiEntry(emoji: "✋", name: "", keywords: [], tones: ["✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"]).emoji(in: tone)
    }
}

/// The picker's sections as a grid of 32 pt cells, with pinned headers.
/// Its own view so it can be rendered without the scroll view around it.
struct EmojiPickerGrid: View {
    let sections: [EmojiPickerSection]
    let loadImage: ((CustomEmojiRef) async throws -> Data)?
    let onChoose: (EmojiPickerItem) -> Void

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 9),
            alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]
        ) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        Button { onChoose(item) } label: { cell(item) }
                            .buttonStyle(.plain)
                            .help(item.name)
                            .accessibilityLabel(item.name)
                    }
                } header: {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .background(.background)
                }
            }
        }
    }

    private func cell(_ item: EmojiPickerItem) -> some View {
        Group {
            if let emoji = item.choice.customEmoji {
                CustomEmojiCell(emoji: emoji, load: loadImage)
            } else {
                Text(item.choice.emoji).font(.system(size: 22))
            }
        }
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
}

/// A custom emoji's picture once it loads; its shortcode before that, without
/// a loader, or when the bytes do not decode.
private struct CustomEmojiCell: View {
    let emoji: CustomEmojiRef
    let load: ((CustomEmojiRef) async throws -> Data)?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(image, scale: 1, label: Text(emoji.displayText))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                Text(emoji.displayText)
                    .font(.system(size: 8))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
            }
        }
        .task(id: emoji) {
            guard let load, image == nil else { return }
            image = await (try? load(emoji)).flatMap(ReactionDisplay.image(from:))
        }
    }
}
