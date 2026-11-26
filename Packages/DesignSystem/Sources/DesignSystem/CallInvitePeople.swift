import ChatKit
import SwiftUI

public struct CallInvitationActions {
    public var search: @MainActor (String) async throws -> [Member]
    public var invite: @MainActor (Member.ID) async throws -> Void

    public init(
        search: @escaping @MainActor (String) async throws -> [Member],
        invite: @escaping @MainActor (Member.ID) async throws -> Void
    ) {
        self.search = search
        self.invite = invite
    }
}

/// Invite People…, a sheet over the call window shaped like Add People: a
/// search, and each person found with an Invite button of their own. Each
/// invitation goes out at once; Done closes, as does Escape.
struct CallInvitePeople: View {
    let actions: CallInvitationActions
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var people: [Member] = []
    @State private var inviting: Member.ID?
    @State private var sent: Set<Member.ID> = []
    @State private var failure: String?
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Invite People")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
                .accessibilityAddTraits(.isHeader)
            Form {
                Section {
                    TextField("Search", text: $query, prompt: Text("Name or email"))
                        .labelsHidden()
                }
                if let failure {
                    Section { SheetErrorRow(message: failure) }
                }
                Section {
                    ForEach(people, id: \.id) { person in
                        PersonRow(person: person) { trailing(person) }
                    }
                    if let hint {
                        Text(hint).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("People")
                        if searching {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 360, idealWidth: 400, minHeight: 340, idealHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: query) { await search() }
        .task(id: inviting) { await invite() }
    }

    /// Invite, its progress, or that the invitation went out.
    @ViewBuilder private func trailing(_ person: Member) -> some View {
        if sent.contains(person.id) {
            Label("Invited", systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if inviting == person.id {
            ProgressView().controlSize(.small)
        } else {
            Button("Invite") { inviting = person.id }
                .controlSize(.small)
                .disabled(inviting != nil)
                .accessibilityLabel("Invite \(PersonName.of(person))")
        }
    }

    /// What the list says while it has nobody to show.
    private var hint: String? {
        guard people.isEmpty, !searching, failure == nil else { return nil }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Search for someone to invite to this call." : "No one matches “\(text)”."
    }

    private func search() async {
        failure = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            people = []; searching = false
            return
        }
        searching = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            let found = try await actions.search(text)
            guard !Task.isCancelled else { return }
            people = found.filter { $0.kind == .human }
            searching = false
        } catch {
            guard !Task.isCancelled else { return }
            people = []; searching = false
            failure = "People couldn’t be loaded."
        }
    }

    private func invite() async {
        guard let id = inviting else { return }
        do {
            try await actions.invite(id)
            guard !Task.isCancelled else { return }
            sent.insert(id); failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            // Never offered again here: a second invitation could ring twice.
            failure = "The invitation couldn’t be confirmed. It may have been sent."
            sent.insert(id)
        }
        inviting = nil
    }
}
