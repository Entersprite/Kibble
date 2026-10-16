import ChatKit
import SwiftUI

struct ConversationCreationPanel: View {
    let kind: Conversation.Kind
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    @State private var name = ""
    @State private var description = ""
    @State private var query = ""
    @State private var selected: [Member] = []
    @State private var highlighted: Member.ID?
    @FocusState private var nameFocused: Bool
    @FocusState private var searchFocused: Bool

    private var title: String {
        switch kind {
        case .space: "New Space"
        case .groupDirectMessage: "New Group Chat"
        default: "New Direct Message"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if kind != .directMessage {
                        TextField(kind == .space ? "Space name" : "Group name (optional)", text: $name)
                            .textFieldStyle(.roundedBorder).focused($nameFocused)
                    }
                    if kind == .space {
                        TextField("Description (optional)", text: $description, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2 ... 4)
                    }
                    if !selected.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(selected, id: \.id) { person in
                                    HStack(spacing: 4) {
                                        Text(person.displayName ?? person.email ?? "Person")
                                        Button("Remove", systemImage: "xmark") {
                                            selected.removeAll { $0.id == person.id }
                                        }
                                        .labelStyle(.iconOnly).buttonStyle(.plain)
                                    }.padding(7).background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                    TextField("Search people by name or email", text: $query)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .onChange(of: query) { highlighted = nil; actions.searchPeople(query) }
                        .onSubmit {
                            if let person = candidates.first(where: { $0.id == highlighted }) ?? candidates
                                .first {
                                choose(person)
                            }
                        }
                        .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                        .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                    if state.browser.isSearchingPeople {
                        ProgressView().controlSize(.small)
                    }
                    List(selection: $highlighted) {
                        ForEach(candidates, id: \.id) { person in
                            Button { choose(person) } label: {
                                HStack {
                                    Avatar(member: person.id, directory: [person.id: person], size: 24)
                                    VStack(alignment: .leading) {
                                        Text(person.displayName ?? person.email ?? "Unknown Person")
                                        if let email = person.email {
                                            Text(email).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).tag(person.id)
                        }
                    }.scrollContentBackground(.hidden)
                        .frame(minHeight: 130, idealHeight: 220, maxHeight: 280)
                    if let error = state.browser.panelError {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                    if state.browser.needsReconciliation {
                        Button("Review Conversations", action: actions.reviewCreation)
                    }
                }
            }
            HStack {
                Button("Cancel", action: actions.closePanel).keyboardShortcut(.cancelAction)
                Spacer()
                if state.browser.isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Button(kind == .directMessage ? "Start Chat" : "Create") {
                    actions.create(ConversationDraft(
                        kind: kind,
                        name: name,
                        members: selected.map(\.id),
                        description: description
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate || state.browser.needsReconciliation)
            }
        }
        .padding(24)
        .disabled(state.browser.isSubmitting)
        .onAppear {
            if kind == .space {
                nameFocused = true
            } else {
                searchFocused = true
            }
        }
    }

    private var canCreate: Bool {
        if kind == .directMessage {
            return selected.count == 1
        }
        if kind == .groupDirectMessage {
            return selected.count >= 2
        }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var candidates: [Member] {
        let people = query.isEmpty ? Array(state.directory.values) : state.browser.pickerPeople
        return people.filter { person in
            person.id != state.me && person.kind == .human && !selected.contains { $0.id == person.id }
        }.sorted { ($0.displayName ?? $0.email ?? "") < ($1.displayName ?? $1.email ?? "") }
    }

    private func moveHighlight(by step: Int) {
        let people = candidates
        guard !people.isEmpty else { return }
        let index = highlighted
            .flatMap { id in people.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : people.count)
        highlighted = people[max(0, min(people.count - 1, index + step))].id
    }

    private func choose(_ person: Member) {
        if kind == .directMessage {
            selected = [person]
        } else {
            selected.append(person)
        }
        query = ""
        searchFocused = true
    }
}

struct ConversationPanelOverlay: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    var body: some View {
        if let browser = actions.browser,
           state.browser.creationKind != nil || state.browser.panelTarget != nil || state.browser
           .panelError != nil {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18).contentShape(Rectangle())
                    VStack {
                        if let kind = state.browser.creationKind {
                            ConversationCreationPanel(kind: kind, state: state, actions: browser)
                                .id(kind)
                        } else if let details = state.browser.details {
                            ConversationManagementPanel(details: details, state: state, actions: actions)
                                .id(details.conversation.id)
                        } else {
                            VStack(spacing: 20) {
                                if let error = state.browser.panelError {
                                    Text(error)
                                } else {
                                    ProgressView("Loading Details…")
                                }
                                Button("Done", action: browser.closePanel)
                            }.padding(24)
                        }
                    }
                    .frame(width: min(580, max(280, geometry.size.width - 48)))
                    .frame(height: min(620, max(280, geometry.size.height - 48)))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(radius: 20)
                    .padding(.top, 24)
                }
            }
        }
    }
}
