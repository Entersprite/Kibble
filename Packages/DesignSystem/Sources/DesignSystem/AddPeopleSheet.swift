import ChatKit
import SwiftUI

/// Add People…, a small sheet over the Info sheet: a search of the
/// directory and the people known here, each with an Add button. Each Add
/// applies at once; Done closes, as do Cancel and Escape.
struct AddPeopleSheet: View {
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        Form {
            Section {
                TextField("Search", text: $query, prompt: Text("Name or email"))
                    .labelsHidden()
                    .onChange(of: query) { actions.searchPeople(query) }
            }
            // The Info sheet's header, which shows a refused add, is under this sheet.
            if let error = state.browser.panelError {
                Section { SheetErrorRow(message: error) }
            }
            AddPeopleResults(query: query, state: state, actions: actions)
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .top) {
            Text("Add People")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 360, idealHeight: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// The people a search finds who are not here yet, each with an Add button.
/// The body of Add People….
struct AddPeopleResults: View {
    let query: String
    let state: ChatSceneState
    let actions: ConversationBrowserActions

    private var isBusy: Bool {
        state.browser.isSubmitting || state.browser.needsReconciliation
    }

    var body: some View {
        Section {
            ForEach(addCandidates, id: \.id) { person in
                PersonRow(person: person) {
                    Button("Add") { actions.mutate(.addPeople([person.id])) }
                        .controlSize(.small)
                        .disabled(isBusy)
                        .accessibilityLabel("Add \(PersonName.of(person))")
                }
            }
            if addCandidates.isEmpty, !query.isEmpty, !state.browser.isSearchingPeople {
                Text("No one else matches “\(query)”.").foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Text(query.isEmpty ? "Suggestions" : "Add People")
                if state.browser.isSearchingPeople {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    private var addCandidates: [Member] {
        PeopleDirectoryProjection.candidates(
            in: state,
            query: query,
            found: state.browser.pickerPeople,
            excluding: Set(state.browser.participants.map(\.id))
        )
    }
}
