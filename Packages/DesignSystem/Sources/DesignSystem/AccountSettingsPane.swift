import SwiftUI

public struct AccountSettingsState: Equatable, Sendable {
    /// The signed-in person's name, or `nil` when nobody is signed in.
    public var signedInAs: String?

    public init(signedInAs: String?) {
        self.signedInAs = signedInAs
    }
}

public struct AccountSettingsPane: View {
    private let state: AccountSettingsState
    private let signOut: (() -> Void)?
    private let exportDiagnostics: (() -> Void)?

    public init(
        state: AccountSettingsState, signOut: (() -> Void)?,
        exportDiagnostics: (() -> Void)? = nil
    ) {
        self.state = state
        self.signOut = signOut
        self.exportDiagnostics = exportDiagnostics
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Signed in as", value: state.signedInAs ?? "Not signed in")
            } footer: {
                Text("Signing out erases this account's conversations from this Mac. "
                    + "Its settings are kept for when you sign in again.")
            }
            if let signOut {
                Section {
                    Button("Sign Out…", action: signOut)
                }
            }
            if let exportDiagnostics {
                Section {
                    Button("Export Diagnostics…", action: exportDiagnostics)
                } footer: {
                    Text("Saves available crash and hang reports, recent read-state errors, "
                        + "history response summaries, and memory samples. The export contains app version, "
                        + "error codes, stack offsets, and request ages. "
                        + "It excludes messages, account details, file paths, and memory addresses. "
                        + "Reopen Kibble after a crash before exporting.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
