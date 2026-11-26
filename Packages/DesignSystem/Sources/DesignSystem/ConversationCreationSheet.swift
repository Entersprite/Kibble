import ChatKit
import SwiftUI

/// New Direct Message, New Group Chat and New Space: a grouped form in a
/// sheet, with Cancel and the default button in the sheet's own placements
/// at the bottom trailing edge, and Review Conversations… leading.
///
/// The people field works like Spotlight (the search overlay's rule): Return
/// adds the top match, ↑↓ or the pointer pick another, with one highlight for
/// both. While the field holds text, Return belongs to it; once it is empty,
/// Return is the default button's again. The confirmation placement gives the
/// default button Return by itself, so its shortcut is taken away while the
/// field holds text (measured in a hosted sheet: the field then gets Return).
struct ConversationCreationSheet: View {
    let kind: Conversation.Kind
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    @State private var name = ""
    @State private var description = ""
    @State private var query = ""
    @State private var selected: [Member] = []
    @State private var highlighted: Member.ID?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, description, people
    }

    var body: some View {
        Form {
            if kind != .directMessage {
                identity
            }
            people
            results
            if let error = state.browser.panelError {
                Section { SheetErrorRow(message: error) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaBar(edge: .top) { SheetHeader(title: title, message: message) }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .frame(width: 480, height: kind == .directMessage ? 400 : 500)
        .toolbar { buttons }
        .disabled(state.browser.isSubmitting)
        // Not `defaultFocus`: in a hosted sheet it left the first field
        // focused, the name, where this puts the people field.
        .onAppear { focus = kind == .space ? .name : .people }
    }

    private var title: String {
        switch kind {
        case .space: "New Space"
        case .groupDirectMessage: "New Group Chat"
        default: "New Message"
        }
    }

    private var message: String {
        switch kind {
        case .space: "A place for a team, project or topic, that people can find and join."
        case .groupDirectMessage: "A conversation with two or more people."
        default: "Choose who to message."
        }
    }

    private var identity: some View {
        Section {
            TextField("Name", text: $name, prompt: Text(kind == .space ? "Required" : "Optional"))
                .focused($focus, equals: .name)
            if kind == .space {
                TextField(
                    "Description",
                    text: $description,
                    prompt: Text("Optional"),
                    axis: .vertical
                )
                .lineLimit(2 ... 4)
                .focused($focus, equals: .description)
            }
        }
    }

    private var people: some View {
        Section {
            ForEach(selected, id: \.id) { person in
                PersonRow(person: person) {
                    Button("Remove \(PersonName.of(person))", systemImage: "minus.circle.fill") {
                        selected.removeAll { $0.id == person.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                }
            }
            if kind != .directMessage || selected.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Add People", text: $query, prompt: Text("Search by name or email"))
                        .labelsHidden()
                        .focused($focus, equals: .people)
                        .onChange(of: query) {
                            highlighted = nil
                            actions.searchPeople(query)
                        }
                        .onSubmit(submitSearch)
                        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                }
            }
        } header: {
            Text(kind == .directMessage ? "To" : "People")
        } footer: {
            if kind == .groupDirectMessage, selected.count < 2 {
                Text("Add at least two people.")
            }
        }
    }

    /// Each match is a button, with one highlight the arrows and the pointer
    /// both move: what Return adds while the field holds text.
    @ViewBuilder private var results: some View {
        if kind != .directMessage || selected.isEmpty {
            Section {
                ForEach(candidates, id: \.id) { person in
                    let isHighlighted = person.id == shownHighlight
                    Button { choose(person) } label: {
                        PersonRow(person: person) {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
                        }
                        .padding(.horizontal, -6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Adds this person")
                    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
                    .onHover { inside in hover(person.id, inside: inside) }
                }
                if candidates.isEmpty, !query.isEmpty, !state.browser.isSearchingPeople {
                    Text("No one matches “\(query)”.").foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(query.isEmpty ? "Suggestions" : "Results")
                    if state.browser.isSearchingPeople {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
        }
    }

    /// A sheet's own placements put Review Conversations… and the spinner at
    /// the leading edge, and Cancel and the default button at the trailing
    /// edge, with Escape and Return (measured in a hosted sheet).
    @ToolbarContentBuilder private var buttons: some ToolbarContent {
        if state.browser.needsReconciliation || state.browser.isSubmitting {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    if state.browser.needsReconciliation {
                        Button("Review Conversations…", action: actions.reviewCreation)
                    }
                    if state.browser.isSubmitting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: actions.closePanel)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(kind == .directMessage ? "Open Chat" : "Create", action: create)
                .keyboardShortcut(query.isEmpty ? .defaultAction : nil)
                .disabled(!canCreate || state.browser.needsReconciliation)
        }
    }

    private var canCreate: Bool {
        switch kind {
        case .directMessage: selected.count == 1
        case .groupDirectMessage: selected.count >= 2
        default: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var candidates: [Member] {
        PeopleDirectoryProjection.candidates(
            in: state,
            query: query,
            found: state.browser.pickerPeople,
            excluding: Set(selected.map(\.id))
        )
    }

    /// The highlighted row, or the top one: what Return adds.
    private var highlightedPerson: Member? {
        let people = candidates
        return people.first { $0.id == highlighted } ?? people.first
    }

    /// The row drawn highlighted (`CreationHighlight.shown`).
    private var shownHighlight: Member.ID? {
        CreationHighlight.shown(query: query, highlighted: highlighted, top: highlightedPerson?.id)
    }

    private func submitSearch() {
        if !query.isEmpty, let person = highlightedPerson {
            choose(person)
        } else if query.isEmpty, canCreate {
            create()
        }
    }

    /// ↑↓ move the highlight while the field holds text. With it empty,
    /// Return creates, so a highlight there would point at nothing.
    private func moveHighlight(by step: Int) -> KeyPress.Result {
        guard !query.isEmpty else { return .ignored }
        let people = candidates
        guard !people.isEmpty else { return .handled }
        let index = highlighted.flatMap { id in people.firstIndex { $0.id == id } } ?? 0
        highlighted = people[max(0, min(people.count - 1, index + step))].id
        return .handled
    }

    private func hover(_ id: Member.ID, inside: Bool) {
        highlighted = CreationHighlight.hovering(id, inside: inside, query: query, highlighted: highlighted)
    }

    private func choose(_ person: Member) {
        if kind == .directMessage {
            selected = [person]
        } else if !selected.contains(where: { $0.id == person.id }) {
            selected.append(person)
        }
        query = ""
        focus = kind == .directMessage ? nil : .people
    }

    private func create() {
        guard canCreate, !state.browser.isSubmitting else { return }
        actions.create(ConversationDraft(
            kind: kind,
            name: name,
            members: selected.map(\.id),
            description: description
        ))
    }
}

/// The creation sheet's one highlight, which the arrows and the pointer share.
enum CreationHighlight {
    /// While the field holds text, the picked row or else the top match: what
    /// Return adds. With the field empty, only a row under the pointer, since
    /// Return then creates.
    static func shown(query: String, highlighted: Member.ID?, top: Member.ID?) -> Member.ID? {
        query.isEmpty ? highlighted : top
    }

    /// The pointer entering a row picks it. Leaving clears the pick only while
    /// the field is empty; with text, it stays for Return, as an arrow's does.
    static func hovering(
        _ id: Member.ID, inside: Bool, query: String, highlighted: Member.ID?
    ) -> Member.ID? {
        if inside {
            return id
        }
        return query.isEmpty && highlighted == id ? nil : highlighted
    }
}
