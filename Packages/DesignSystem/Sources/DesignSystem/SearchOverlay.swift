import ChatKit
import SwiftUI

/// Search, Spotlight-like: a Liquid Glass panel over the chat window with the
/// field, the filter chips and three sections (search spec §1), ported from
/// the owner's approved mockup (`Spikes/search-overlay`).
///
/// The view keeps only what is its own: the field's text, the selected row
/// and the focus. Everything else is the window's `SearchSceneState`, and
/// every change goes back through `SearchActions`.
public struct SearchOverlay: View {
    let state: ChatSceneState
    let actions: SearchActions
    /// The From chip's people, everyone named in the directory, by name; and
    /// every conversation's title for the hits' "in …". Built here rather than
    /// in `body`, so a hover or a key that redraws only this view does not
    /// sort the directory again.
    private let filterPeople: [Member]
    private let conversationTitles: [Conversation.ID: String]

    @State private var text: String
    /// What `actions.textChanged` was last told, so a text set here alongside
    /// a query (Clear, "Messages From") is not sent a second time.
    @State private var sent: String
    @State private var selection: SearchRow?
    /// Whether `selection` came from ↑↓ or a hover since the last keystroke,
    /// so it survives a rows update that still lists it. A keystroke clears
    /// this; the next rows update then lands on the top result (Spotlight).
    @State private var explicitPick = false
    @FocusState private var focused: Bool

    public init(state: ChatSceneState, actions: SearchActions) {
        self.state = state
        self.actions = actions
        _text = State(initialValue: state.search.query.text)
        _sent = State(initialValue: state.search.query.text)
        let directory = state.directory
        filterPeople = directory.values
            .filter { $0.kind == .human && $0.displayName != nil }
            .map { (member: $0, name: Display.name(of: $0.id, in: directory)) }
            .sorted { $0.name < $1.name }
            .map(\.member)
        conversationTitles = Dictionary(
            state.conversations.map { ($0.id, Display.title(of: $0, directory: directory, me: state.me)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var search: SearchSceneState {
        state.search
    }

    private var words: [String] {
        SearchPresentation.words(search.query.text)
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Not under the toolbar's band, which takes no clicks.
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.hide() }
                    // Escape closes the panel too, so VoiceOver has no use
                    // for the dimmed window behind it.
                    .accessibilityHidden(true)
                panel
                    .frame(width: SearchOverlayLayout.panelWidth(for: geo.size.width))
                    .frame(
                        maxHeight: SearchOverlayLayout.panelMaxHeight(for: geo.size.height),
                        alignment: .top
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SearchOverlayLayout.topInset)
            }
        }
        .onAppear {
            if let hit = SearchRows.initialSelection(search) {
                selection = hit
                explicitPick = true
            } else {
                selection = SearchRows.rows(search).first
                explicitPick = false
            }
            // A hop rather than `defaultFocus`, which a hosted test could not
            // show landing in a view inserted into a window already focused.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: text) {
            guard text != sent else { return }
            // Typing drops the pick; the next rows update lands on the top
            // result (Spotlight-like), so Return opens it unless the person
            // arrows to another row first.
            explicitPick = false
            // Also now: a keystroke that leaves the rows as they were fires no
            // rows update, and must not leave an arrow pick selected.
            selection = SearchRows.rows(search).first
            sent = text
            actions.textChanged(text)
        }
        .onChange(of: search.query.text) { _, modelText in
            // Set without typing (a person row, ⌘F back to the bar's search):
            // the field follows, and sends nothing.
            guard let adopted = SearchRows.adopted(modelText, sent: sent) else { return }
            sent = adopted
            text = adopted
        }
        .onChange(of: search.focusGeneration) {
            // ⌘F back to the bar's list (`search.focusGeneration` is the
            // signal, not `search.focus`'s value: pressing it again at the
            // same bar position restamps the same hit, which `focus` alone
            // would not change, and nothing here clears it to `nil` first to
            // force a change, which would flash the selection). A focus
            // cleared by a new answer leaves the pick to the rows-change
            // handler below.
            guard search.focus != nil else { return }
            if let hit = SearchRows.initialSelection(search) {
                selection = hit
                explicitPick = true
            } else {
                selection = SearchRows.rows(search).first
                explicitPick = false
            }
        }
        .onChange(of: SearchRows.rows(search)) { _, rows in
            selection = SearchRows.selected(previous: selection, explicit: explicitPick, in: rows)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            SearchFilterRow(
                query: search.query,
                filters: state.capabilities.messageSearchFilters,
                people: filterPeople,
                conversations: state.conversations,
                directory: state.directory,
                me: state.me,
                setQuery: actions.setQuery
            )
            Divider()
            results
            Divider()
            footer
        }
        // The shape a row's highlight follows (`ConcentricRectangle`).
        .containerShape(SearchOverlayLayout.panelShape)
        // Nothing clipped after the glass: it already takes the panel's
        // shape, and a clip would cut into the effect's own edge. Nothing in
        // the panel reaches its corners to need one.
        .glassEffect(.regular, in: SearchOverlayLayout.panelShape)
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        // One element VoiceOver stays inside while it is open, as in a sheet.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: The field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Search messages, people and conversations", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { actions.hide(); return .handled }
                .onSubmit {
                    switch SearchRows.returnAction(selected: selection, rows: SearchRows.rows(search)) {
                    case let .open(row): open(row)
                    case .submit: actions.submit()
                    }
                }
            if !text.isEmpty || search.query.hasFilters {
                Button {
                    replace(text: "", query: MessageSearchQuery(order: search.query.order))
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func move(_ step: Int) {
        selection = SearchRows.next(after: SearchRows.rows(search), selected: selection, by: step)
        explicitPick = true
    }

    /// Sets the text and the filters together: the text first, so the query
    /// the model keeps carries it, then the filters, which search at once.
    private func replace(text newText: String, query: MessageSearchQuery) {
        sent = newText
        text = newText
        actions.textChanged(newText)
        actions.setQuery(query)
    }

    private func open(_ row: SearchRow) {
        switch row {
        case let .recent(recent):
            // Searches at once: the text first, so the submit carries it.
            sent = recent
            text = recent
            actions.textChanged(recent)
            actions.submit()
        case let .conversation(id): actions.openConversation(id)
        case let .person(id): actions.openPerson(id)
        case let .message(id): actions.openMessage(id)
        }
    }

    // MARK: Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if SearchRows.showsRecents(search) {
                        recents
                    } else {
                        sections
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .frame(minHeight: 120, maxHeight: 420)
            .onChange(of: selection) {
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selection) }
            }
        }
    }

    @ViewBuilder private var recents: some View {
        header("Recent Searches")
        ForEach(search.recents, id: \.self) { recent in
            row(.recent(recent)) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(recent)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder private var sections: some View {
        if !search.conversations.isEmpty {
            header("Conversations")
            ForEach(search.conversations, id: \.id) { conversation in
                row(.conversation(conversation.id)) {
                    ConversationHit(
                        conversation: conversation,
                        directory: state.directory,
                        me: state.me,
                        words: words
                    )
                }
            }
        }
        if !search.people.isEmpty {
            header("People")
            ForEach(search.people, id: \.id) { person in
                row(.person(person.id)) {
                    PersonHit(
                        person: person,
                        directory: state.directory,
                        words: words,
                        messagesFrom: messagesFrom(person)
                    )
                }
            }
        }
        // Below the model's floor nothing is searched, so nothing is said.
        if SearchRows.searchesMessages(search.query) {
            messages
        }
    }

    private func messagesFrom(_ person: Member) -> (() -> Void)? {
        guard state.capabilities.messageSearchFilters.contains(.from) else { return nil }
        return {
            var query = search.query
            query.from = person.id
            replace(text: "", query: query)
        }
    }

    @ViewBuilder private var messages: some View {
        header(
            "Messages",
            trailing: search.isSearching ? nil : "\(search.hits.count)",
            loading: search.isSearching
        )
        if search.failed {
            note("Couldn't search right now.")
        } else if !search.isSearching, search.hits.isEmpty, !search.hasMore {
            note("No messages match. Try another word or remove a filter.")
        }
        let titles = conversationTitles
        ForEach(search.hits, id: \.id) { message in
            row(.message(message.id)) {
                MessageHit(
                    message: message, directory: state.directory,
                    conversationTitle: titles[message.conversationID], words: words
                )
            }
        }
        switch SearchRows.more(search) {
        case .loading?:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        case .retry?:
            HStack(spacing: 8) {
                Text("Couldn't load more results.").foregroundStyle(.secondary)
                Button("Try Again", action: actions.loadMore).controlSize(.small)
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        case .trigger?:
            // A new trigger per page, so the next one appears at the new end.
            if search.hits.isEmpty {
                Button("Search More Messages", action: actions.loadMore)
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
            } else {
                Color.clear.frame(height: 1)
                    .id("more-\(search.hits.count)")
                    .onAppear { actions.loadMore() }
            }
        case nil:
            EmptyView()
        }
    }
}

/// A row, outside the struct so its body stays in lint's limit.
private extension SearchOverlay {
    /// A row is one button to VoiceOver: its words, whether it is the one
    /// Return opens, and opening it as the default action. A person row's
    /// "Messages From" button is combined into it; that VoiceOver offers it
    /// as the row's second action is `[Verify]`.
    func row(_ row: SearchRow, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                // Rounded in step with the panel's corners.
                ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
                    .fill(selection == row ? Color.accentColor.opacity(0.22) : .clear)
            }
            .contentShape(Rectangle())
            .onTapGesture { open(row) }
            .onHover { inside in
                if inside {
                    selection = row
                    explicitPick = true
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selection == row ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open(row) }
            .padding(.horizontal, 8)
            .id(row)
    }
}
