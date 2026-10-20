import ChatAPI
import Foundation

/// Sign Out keeps an account and its settings until it signs in again as
/// itself; Remove Account forgets both.
public extension SystemAccountHost {
    /// Removes the account with everything kept for it: its credentials, this
    /// Mac's copy of its conversations, and its settings.
    func removeAccount(_ id: String) async {
        guard let workspace else { return }
        do {
            try await workspace.remove(ConnectedAccountID(id), forgettingSettings: true)
        } catch {
            self.error = "The account could not be removed. Try again."
        }
    }

    /// Signs the account out and keeps it, with its settings, until it is
    /// signed in again as the same account.
    func signOutAccount(_ id: String) async {
        do {
            try await workspace?.signOut(ConnectedAccountID(id))
        } catch { self.error = "The account could not sign out. Try again." }
    }

    /// Lists the accounts in `order`, by account id.
    func reorderAccounts(_ order: [String]) async {
        do {
            try await workspace?.reorder(order.map { ConnectedAccountID($0) })
        } catch { self.error = "The accounts could not be reordered. Try again." }
    }

    /// Picks up a sign-in that was started and not finished: its window opens
    /// again while it still waits for the browser, and it completes otherwise.
    func resumeSignIn(_ id: String) async {
        guard let workspace else { return }
        do {
            try await workspace.resumeLink(AccountLinkID(id))
        } catch {
            self.error = "That sign-in could not continue. Try adding the account again."
            return
        }
        if workspace.capture != nil {
            await beginSignIn()
        }
    }
}
