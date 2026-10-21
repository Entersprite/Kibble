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
    /// `false` in the composer, which inserts text: a custom emoji is not
    /// text, and is offered nowhere, recents included.
    var offersCustom = true

    var sections: [EmojiPickerSection] {
        let custom = offersCustom ? custom : []
        let recents = offersCustom ? recents : recents.filter { $0.customEmoji == nil }
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
/// on open, a skin-tone control, a row of category buttons, and the sections
/// as a grid. Choosing calls back with the choice and whether it adds, and
/// the host closes the popover.
///
/// The keyboard stays in the search field, and the arrows move one highlight
/// through the grid (`EmojiPickerNavigation`) that the pointer moves too;
/// Return chooses the highlighted emoji, or the first result of a query.
/// Left and Right reach the grid only once something is highlighted, so they
/// still move the field's caret while typing.
struct EmojiPicker: View {
    let reactions: [Reaction]
    let actions: ReactionActions
    let onChoose: (ReactionChoice, Bool) -> Void
    /// `false` in the composer (`EmojiPickerModel.offersCustom`).
    let offersCustom: Bool

    @State private var query = ""
    @State private var tone: SkinTone
    @State private var recents: [ReactionChoice] = []
    @State private var custom: [CustomEmojiRef] = []
    /// The highlighted cell, by `EmojiPickerGrid.cellID`.
    @State private var highlight: String?
    @FocusState private var searchFocused: Bool

    init(
        reactions: [Reaction],
        actions: ReactionActions,
        offersCustom: Bool = true,
        onChoose: @escaping (ReactionChoice, Bool) -> Void
    ) {
        self.reactions = reactions
        self.actions = actions
        self.offersCustom = offersCustom
        self.onChoose = onChoose
        _tone = State(initialValue: actions.skinTone)
    }

    private var model: EmojiPickerModel {
        EmojiPickerModel(
            catalog: .bundled, recents: recents, custom: custom, reactions: reactions, tone: tone,
            query: query, offersCustom: offersCustom
        )
    }

    var body: some View {
        let sections = model.sections
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Search Emoji", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onSubmit { chooseHighlighted(in: sections) }
                        .onKeyPress(.downArrow) { move(.down, in: sections) }
                        .onKeyPress(.upArrow) { move(.up, in: sections) }
                        .onKeyPress(.leftArrow) { highlight == nil ? .ignored : move(.left, in: sections) }
                        .onKeyPress(.rightArrow) { highlight == nil ? .ignored : move(.right, in: sections) }
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
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sections.count > 1 {
                    EmojiCategoryBar(sections: sections) { section in
                        withAnimation { proxy.scrollTo(EmojiPickerGrid.headerID(section), anchor: .top) }
                    }
                }
                Divider()
                ScrollView {
                    if sections.isEmpty {
                        Text("No emoji found")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    EmojiPickerGrid(
                        sections: sections, loadImage: actions.customImage, highlight: highlight,
                        onHover: { highlight = $0 }, onChoose: choose
                    )
                    .padding(8)
                }
            }
            .onChange(of: highlight) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
        .frame(width: 340, height: 380)
        .onChange(of: query) { highlight = nil }
        .onAppear {
            recents = actions.recents()
            custom = actions.customCatalog()
            searchFocused = true
        }
    }

    private func move(
        _ direction: EmojiPickerNavigation.Direction, in sections: [EmojiPickerSection]
    ) -> KeyPress.Result {
        let navigation = EmojiPickerNavigation(sections: sections.map { section in
            section.items.map { EmojiPickerGrid.cellID(section, $0) }
        })
        let next = navigation.move(from: highlight, direction)
        guard next != nil || highlight != nil else { return .ignored }
        highlight = next
        return .handled
    }

    private func chooseHighlighted(in sections: [EmojiPickerSection]) {
        if let highlight, let item = EmojiPickerGrid.item(highlight, in: sections) {
            choose(item)
        } else if let first = model.firstResult {
            choose(first)
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

/// One icon-only button per section, scrolling the grid to it. Not focusable:
/// the search field keeps the keyboard, and the arrows already reach every
/// section.
private struct EmojiCategoryBar: View {
    let sections: [EmojiPickerSection]
    let jump: (EmojiPickerSection) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sections) { section in
                Button { jump(section) } label: {
                    Label(section.title, systemImage: EmojiCategorySymbols.symbol(for: section.title))
                        .labelStyle(.iconOnly)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(section.title)
                .focusable(false)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// The picker's sections as a grid of 32 pt cells, with pinned headers.
/// Its own view so it can be rendered without the scroll view around it.
struct EmojiPickerGrid: View {
    nonisolated static let columns = 9

    let sections: [EmojiPickerSection]
    let loadImage: ((CustomEmojiRef) async throws -> Data)?
    /// The highlighted cell, by `cellID`; `nil` highlights none.
    var highlight: String?
    /// The pointer entered a cell (its id) or left the highlighted one (`nil`).
    var onHover: ((String?) -> Void)?
    let onChoose: (EmojiPickerItem) -> Void

    /// An emoji can be in Recent and in its category at once, so a cell is
    /// named by its section too.
    static func cellID(_ section: EmojiPickerSection, _ item: EmojiPickerItem) -> String {
        "\(section.id)/\(item.id)"
    }

    static func headerID(_ section: EmojiPickerSection) -> String {
        "header/\(section.id)"
    }

    static func item(_ cellID: String, in sections: [EmojiPickerSection]) -> EmojiPickerItem? {
        for section in sections {
            if let item = section.items.first(where: { Self.cellID(section, $0) == cellID }) {
                return item
            }
        }
        return nil
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: Self.columns),
            alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]
        ) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        let id = Self.cellID(section, item)
                        Button { onChoose(item) } label: { cell(item) }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .background(AccountPanelHighlight(isOn: highlight == id, cornerRadius: 6))
                            .onHover { inside in
                                if inside {
                                    onHover?(id)
                                } else if highlight == id {
                                    onHover?(nil)
                                }
                            }
                            .help(item.name)
                            .accessibilityLabel(item.name)
                            .accessibilityAddTraits(highlight == id ? .isSelected : [])
                            .id(id)
                    }
                } header: {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .background(.background)
                        .accessibilityAddTraits(.isHeader)
                        .id(Self.headerID(section))
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
