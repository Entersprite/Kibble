import SwiftUI

/// Native modal confirmation; labels and actions are captured for one account.
public struct AccountConfirmationSheet: View {
    let label: String
    let removing: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    public init(label: String, removing: Bool, confirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.label = label; self.removing = removing; self.confirm = confirm; self.cancel = cancel
    }

    private var message: String {
        if removing {
            return "Kibble erases this account’s conversations, files and settings from this Mac. "
                + "A call on this account ends."
        }
        return "Kibble keeps this account and its settings, and erases its conversations from this Mac. "
            + "Sign in again with the same account to get them back."
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(removing ? "Remove \(label) from Kibble?" : "Sign out of \(label)?")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(removing ? "Remove Account" : "Sign Out", role: .destructive, action: confirm)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 420)
    }
}
