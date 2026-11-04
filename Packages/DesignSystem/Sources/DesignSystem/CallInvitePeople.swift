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

struct CallInvitePeople: View {
    let actions: CallInvitationActions
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var people: [Member] = []
    @State private var inviting: Member.ID?
    @State private var selected: Member.ID?
    @State private var sent: Set<Member.ID> = []
    @State private var failure: String?
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite People").font(.headline)
            TextField("Search by name or email", text: $query)
                .textFieldStyle(.roundedBorder)
                .disabled(inviting != nil)
            if searching {
                ProgressView().controlSize(.small)
            }
            List(people, id: \.id, selection: $selected) { member in
                HStack {
                    Text(member.displayName ?? member.email ?? "Person")
                    Spacer()
                    if sent.contains(member.id) {
                        Label("Invited", systemImage: "checkmark")
                    }
                }.tag(member.id)
            }
            .frame(minHeight: 180)
            .disabled(inviting != nil)
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if inviting != nil {
                    ProgressView().controlSize(.small)
                }
                Button("Invite") { inviting = selected }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || inviting != nil || selected.map(sent.contains) == true)
            }
        }
        .padding(20).frame(width: 360)
        .task(id: query) {
            people = []; selected = nil; failure = nil
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(250))
                let found = try await actions.search(text)
                guard !Task.isCancelled else { return }
                people = found.filter { $0.kind == .human }
                searching = false
            } catch {
                guard !Task.isCancelled else { return }
                searching = false; failure = "People could not be loaded."
            }
        }
        .task(id: inviting) {
            guard let id = inviting else { return }
            do {
                try await actions.invite(id)
                guard !Task.isCancelled else { return }
                sent.insert(id); failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                failure = "The invitation could not be confirmed. It may have been sent."
                sent.insert(id)
            }
            inviting = nil
        }
    }
}
