import ChatKit
import SwiftUI

/// New Direct Message, New Group Chat and New Space: a grouped form in a
/// sheet, with Cancel and the default button at the bottom trailing edge.
///
/// The people field works like Spotlight (the search overlay's rule): Return
/// adds the top match, ↑↓ pick another. While the field holds text, Return
/// belongs to it; once it is empty, Return is the default button's again.
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
        .safeAreaBar(edge: .bottom) { buttons }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .frame(width: 480, height: kind == .directMessage ? 460 : 560)
        .disabled(state.browser.isSubmitting)
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
                        .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                        .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
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

    @ViewBuilder private var results: some View {
        if kind != .directMessage || selected.isEmpty {
            Section {
                ForEach(candidates, id: \.id) { person in
                    PersonRow(person: person) {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(highlightedPerson?.id == person.id && !query.isEmpty
                                ? Color.accentColor.opacity(0.18) : .clear)
                    }
                    .padding(.horizontal, -6)
                    .onTapGesture { choose(person) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { choose(person) }
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

    private var buttons: some View {
        SheetButtonBar {
            if state.browser.needsReconciliation {
                Button("Review Conversations…", action: actions.reviewCreation)
            }
            if state.browser.isSubmitting {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: actions.closePanel)
                .keyboardShortcut(.cancelAction)
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

    private func submitSearch() {
        if !query.isEmpty, let person = highlightedPerson {
            choose(person)
        } else if query.isEmpty, canCreate {
            create()
        }
    }

    private func moveHighlight(by step: Int) {
        let people = candidates
        guard !people.isEmpty else { return }
        let index = highlighted.flatMap { id in people.firstIndex { $0.id == id } } ?? 0
        highlighted = people[max(0, min(people.count - 1, index + step))].id
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
