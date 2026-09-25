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

    public init(state: AccountSettingsState, signOut: (() -> Void)?) {
        self.state = state
        self.signOut = signOut
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Signed in as", value: state.signedInAs ?? "Not signed in")
            } footer: {
                Text("Signing out forgets this session and the local message history. "
                    + "Notification settings are kept for when you sign in again.")
            }
            if let signOut {
                Section {
                    Button("Sign Out…", action: signOut)
                }
            }
        }
        .formStyle(.grouped)
    }
}
