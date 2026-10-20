import SwiftUI

/// "Sign out of …?" or "Remove … from Kibble?", as a native alert for the
/// account captured when asked, so a later switch never retargets it.
///
/// Remove has no default button, so Return cannot erase an account before
/// the alert is read; Esc cancels. Sign Out was chosen on purpose and is undone
/// by signing in again, so Return confirms it, as it does for Empty Trash.
/// Neither shows the caution symbol, which is for unexpected loss of data.
struct AccountConfirmation: ViewModifier {
    let kind: AccountConfirmationKind
    @Binding var account: String?
    let label: (String) -> String
    let confirm: (String) -> Void

    func body(content: Content) -> some View {
        content.alert(
            account.map(title) ?? "",
            isPresented: Binding(get: { account != nil }, set: {
                if !$0 {
                    account = nil
                }
            }),
            presenting: account
        ) { id in
            switch kind {
            case .signOut:
                Button("Sign Out") { confirm(id) }
                    .keyboardShortcut(.defaultAction)
            case .remove:
                Button("Remove", role: .destructive) { confirm(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(message)
        }
    }

    private func title(_ id: String) -> String {
        switch kind {
        case .signOut: "Sign out of \(label(id))?"
        case .remove: "Remove \(label(id)) from Kibble?"
        }
    }

    private var message: String {
        switch kind {
        case .signOut:
            "Kibble keeps this account and its settings, and erases its conversations from this Mac. "
                + "Sign in again with the same account to get them back."
        case .remove:
            "Kibble erases this account’s conversations, files and settings from this Mac. "
                + "A call on this account ends."
        }
    }
}

public enum AccountConfirmationKind: Sendable {
    /// Keeps the account and its settings until it signs in again.
    case signOut
    /// Forgets the account and its settings.
    case remove
}

public extension View {
    /// Asks before signing out of, or removing, the account in `account`;
    /// `label` names it, and `confirm` receives the id captured when asked.
    func accountConfirmation(
        _ kind: AccountConfirmationKind, account: Binding<String?>,
        label: @escaping (String) -> String, confirm: @escaping (String) -> Void
    ) -> some View {
        modifier(AccountConfirmation(kind: kind, account: account, label: label, confirm: confirm))
    }
}
