import ChatKit
import SwiftUI

extension ConversationList {
    @ViewBuilder
    func sectionActions(_ section: SidebarSection) -> some View {
        if let id = section.customSectionID {
            if let save = actions.editConversationSection,
               let current = state.conversationSections.first(where: { $0.id == id }) {
                Button {
                    editingSection = SidebarSectionEditing(
                        section: current, save: save, delete: actions.deleteConversationSection
                    )
                } label: {
                    Label("Edit Section", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .help("Edit Section")
            }
        } else if let update = actions.updateSidebar {
            SidebarSectionMenu(
                id: section.id, preferences: state.sidebarPreferences, update: update,
                showSettings: actions.showSidebarSettings
            )
        }
    }
}

struct SidebarSectionEditing: Identifiable {
    let section: ConversationSection
    let save: (ConversationSectionEdit) async throws -> Void
    let delete: ((String) async throws -> Void)?

    var id: String {
        section.id
    }
}

struct ConversationSectionEditor: View {
    private enum Mode {
        case create((String) async throws -> Void)
        case edit(ConversationSection, (ConversationSectionEdit) async throws -> Void)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var sort: SidebarSortOrder
    @State private var unreadOnly: Bool
    @State private var saveTask: Task<Void, Never>?
    @State private var saveFailed = false
    @State private var confirmDelete = false

    private let mode: Mode
    private let delete: ((String) async throws -> Void)?

    init(
        section: ConversationSection, save: @escaping (ConversationSectionEdit) async throws -> Void,
        delete: ((String) async throws -> Void)? = nil
    ) {
        mode = .edit(section, save)
        self.delete = delete
        _name = State(initialValue: section.name)
        _sort = State(initialValue: section.sort)
        _unreadOnly = State(initialValue: section.unreadOnly)
    }

    init(create: @escaping (String) async throws -> Void) {
        mode = .create(create)
        delete = nil
        _name = State(initialValue: "")
        _sort = State(initialValue: .activity)
        _unreadOnly = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section == nil ? "New Section" : "Edit Section")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Required"))
                    if section != nil {
                        Picker("Sort By", selection: $sort) {
                            ForEach([SidebarSortOrder.activity, .name], id: \.self) {
                                Text(SidebarSortTitles.sort($0)).tag($0)
                            }
                        }
                        Toggle("Show Unread Conversations Only", isOn: $unreadOnly)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(saveTask != nil)
            if saveFailed {
                Text("The section change couldn’t be confirmed.")
                    .foregroundStyle(.red)
            }
            buttons
        }
        .padding(20)
        .frame(width: 380)
        .frame(minHeight: section == nil ? 216 : 260, idealHeight: section == nil ? 232 : 280)
        .interactiveDismissDisabled(saveTask != nil)
        .onDisappear { saveTask?.cancel() }
        .alert("Delete Section?", isPresented: $confirmDelete, presenting: section) { current in
            Button("Delete Section", role: .destructive) {
                if let delete {
                    write { try await delete(current.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { current in
            Text("Conversations in “\(current.name)” will return to their usual sidebar groups.")
        }
    }

    private var buttons: some View {
        HStack {
            if delete != nil {
                Button("Delete Section…", role: .destructive) { confirmDelete = true }
                    .disabled(saveTask != nil)
            }
            if saveTask != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating Section")
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(saveTask != nil)
            Button(section == nil ? "Create" : "Save", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(saveTask != nil || !canSave)
        }
    }

    private var section: ConversationSection? {
        if case let .edit(section, _) = mode {
            section
        } else {
            nil
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        if let section {
            edit(of: section).isValid
        } else {
            ConversationSection.isValidName(trimmedName)
        }
    }

    private func edit(of section: ConversationSection) -> ConversationSectionEdit {
        ConversationSectionEdit(
            id: section.id,
            name: name == section.name ? nil : trimmedName,
            sort: sort == section.sort ? nil : sort,
            unreadOnly: unreadOnly == section.unreadOnly ? nil : unreadOnly
        )
    }

    private func submit() {
        guard canSave else { return }
        switch mode {
        case let .create(create):
            let name = trimmedName
            write { try await create(name) }
        case let .edit(section, save):
            let edit = edit(of: section)
            write { try await save(edit) }
        }
    }

    private func write(_ perform: @escaping () async throws -> Void) {
        guard saveTask == nil else { return }
        saveFailed = false
        saveTask = Task {
            defer { saveTask = nil }
            do {
                try await perform()
                try Task.checkCancellation()
                dismiss()
            } catch {
                if !Task.isCancelled {
                    saveFailed = true
                }
            }
        }
    }
}
