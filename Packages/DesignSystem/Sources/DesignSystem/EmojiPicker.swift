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
    /// `false` where the choice is text (`EmojiPickerUse.text`): a custom
    /// emoji is not text, and is offered nowhere, recents included.
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

/// Whether the host can preserve a typed custom choice. Text-only hosts
/// exclude custom recents as well as the Custom section.
enum EmojiPickerUse: Equatable {
    case reaction, text

    var offersCustom: Bool {
        self == .reaction
    }
}

/// The full picker (reactions spec §4.3), in a popover: a search field focused
/// on open, a skin-tone control, a row of category buttons, and the sections
/// as a grid. Choosing calls back with the choice and whether it adds, and
/// the host closes the popover. Every entry point presents this one view,
/// with the same `ReactionActions`; only `use` differs.
///
/// The keyboard stays in the search field, and the arrows move one highlight
/// through the grid (`EmojiPickerNavigation`) that the pointer moves too;
/// Return chooses the highlighted emoji, or the first result of a query.
/// Left and Right reach the grid only once something is highlighted, so they
/// still move the field's caret while typing. Only the arrows scroll to the
/// highlight: under the pointer it is already in view, and scrolling there
/// moved the grid out from under it.
struct EmojiPicker: View {
    let reactions: [Reaction]
    let actions: ReactionActions
    let use: EmojiPickerUse
    let onChoose: (ReactionChoice, Bool) -> Void

    @State private var query = ""
    @State private var tone: SkinTone
    /// The highlighted cell, by `EmojiPickerGrid.cellID`. Only the grid reads
    /// it while drawing, so a pointer move does not rebuild the picker
    /// around the grid.
    @State private var highlight: String?
    @FocusState private var searchFocused: Bool

    init(
        reactions: [Reaction],
        actions: ReactionActions,
        use: EmojiPickerUse,
        onChoose: @escaping (ReactionChoice, Bool) -> Void
    ) {
        self.reactions = reactions
        self.actions = actions
        self.use = use
        self.onChoose = onChoose
        _tone = State(initialValue: actions.skinTone)
    }

    /// Recents and custom emoji come from the host on every render, which
    /// answers from memory (`ReactionActions`): custom emoji that arrive while
    /// the picker is open show without reopening it.
    private var model: EmojiPickerModel {
        EmojiPickerModel(
            catalog: .bundled, recents: actions.recents(), custom: actions.customCatalog(),
            reactions: reactions, tone: tone, query: query, offersCustom: use.offersCustom
        )
    }

    var body: some View {
        let model = model
        let sections = model.sections
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Search Emoji", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onSubmit { chooseHighlighted(in: sections, model: model) }
                        .onKeyPress(.downArrow) { move(.down, in: sections, proxy) }
                        .onKeyPress(.upArrow) { move(.up, in: sections, proxy) }
                        .onKeyPress(.leftArrow) { highlight == nil ? .ignored : move(
                            .left,
                            in: sections,
                            proxy
                        ) }
                        .onKeyPress(.rightArrow) { highlight == nil ? .ignored : move(
                            .right,
                            in: sections,
                            proxy
                        ) }
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
                        sections: sections, reactions: model.reactions, loadImage: actions.customImage,
                        highlight: $highlight, onChoose: onChoose
                    )
                    .padding(8)
                }
            }
        }
        .frame(width: 340, height: 380)
        .onChange(of: query) { highlight = nil }
        .onAppear { searchFocused = true }
    }

    private func move(
        _ direction: EmojiPickerNavigation.Direction, in sections: [EmojiPickerSection],
        _ proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let navigation = EmojiPickerNavigation(sections: sections.map { section in
            section.items.map { EmojiPickerGrid.cellID(section, $0) }
        })
        let next = navigation.move(from: highlight, direction)
        guard next != nil || highlight != nil else { return .ignored }
        highlight = next
        if let next {
            proxy.scrollTo(next)
        }
        return .handled
    }

    private func chooseHighlighted(in sections: [EmojiPickerSection], model: EmojiPickerModel) {
        if let highlight, let item = EmojiPickerGrid.item(highlight, in: sections) {
            onChoose(item.choice, model.adds(item))
        } else if let first = model.firstResult {
            onChoose(first.choice, model.adds(first))
        }
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

/// The picker's sections as a grid of cells up to 32 pt, each under its
/// header.
/// Its own view so it can be rendered without the scroll view around it.
///
/// Each cell is named by `cellID` in the `ForEach`, so
/// `ScrollViewProxy.scrollTo` finds a cell the lazy grid has not built yet.
/// Built inline with an `.id` on each, every move redrew all of them and
/// scrolling had the grid build its cells to find one: about a third of a
/// second each time the pointer crossed into another cell (measured hosted).
struct EmojiPickerGrid: View {
    nonisolated static let columns = 9

    let sections: [EmojiPickerSection]
    /// The message's reactions, for whether choosing a cell adds or removes.
    var reactions: [Reaction] = []
    let loadImage: ((CustomEmojiRef) async throws -> Data)?
    /// The highlighted cell, by `cellID`; `nil` highlights none. The pointer
    /// sets it on entering a cell and clears it on leaving the highlighted one.
    @Binding var highlight: String?
    /// The choice, and whether it adds.
    let onChoose: (ReactionChoice, Bool) -> Void

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

    /// Nine columns that share the width the scroll view leaves: up to 32 pt
    /// each, narrower when a scroller that is always shown takes its 15 pt,
    /// which fixed 32-pt columns overran. (The saluting face's right side is
    /// cut on macOS 27 wherever it is drawn, by AppKit text drawing too, so
    /// it is not a column clipping.)
    nonisolated static let gridColumns = Array(
        repeating: GridItem(.flexible(minimum: 28, maximum: 32), spacing: 4),
        count: columns
    )

    var body: some View {
        // Headers scroll with their emoji rather than pinning: a pinned
        // header needs a background of its own, and in the picker's glass
        // popover that drew as a solid band. The category bar jumps between
        // sections instead.
        LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 4) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items.map { (Self.cellID(section, $0), $0) }, id: \.0) { id, item in
                        EmojiPickerCell(
                            item: item,
                            adds: QuickReactions.adds(item.choice, to: reactions),
                            isHighlighted: highlight == id,
                            loadImage: loadImage,
                            onHover: { inside in
                                if inside {
                                    highlight = id
                                } else if highlight == id {
                                    highlight = nil
                                }
                            },
                            onChoose: onChoose
                        )
                    }
                } header: {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                        .id(Self.headerID(section))
                }
            }
        }
    }
}
