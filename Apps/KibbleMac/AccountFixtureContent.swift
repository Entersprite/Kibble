import AppCore
import DesignSystem
import MacHost
import SwiftUI

/// A fixture-only entry to the account workspace while production parity and
/// existing-login migration are completed in the host.
struct AccountFixtureContent<Content: View>: View {
    let host: SystemAccountFixtureHost
    @ViewBuilder let content: () -> Content
    @State private var removingAccount: String?

    var body: some View {
        HStack(spacing: 0) {
            if let workspace = host.workspace {
                AccountRail(
                    accounts: workspace.accounts.map { account in
                        AccountRailItem(
                            id: account.id.rawValue, label: account.label,
                            badge: workspace.environment(for: account.id)?.badgeCount ?? 0,
                            isEnabled: account.isEnabled,
                            hasIssue: account.authenticationState != nil || workspace
                                .accountErrors[account.id] != nil
                        )
                    },
                    selected: workspace.selectedID?.rawValue,
                    select: host.selectAccount,
                    toggle: { item in Task { await host.setEnabled(!item.isEnabled, account: item.id) } },
                    remove: { removingAccount = $0 },
                    add: { Task { await host.addAccount() } },
                    simulateMessage: { id in Task { await host.simulateMessage(id) } }
                )
                Divider()
                if workspace.selectedEnvironment != nil {
                    content().id(workspace.selectedID?.rawValue)
                } else {
                    placeholder(workspace)
                }
            } else if let error = host.error {
                Text(error).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Starting accounts…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if let error = host.error {
                HStack {
                    Text(error)
                    Button("Dismiss") { host.dismissError() }
                }
                .padding(10).background(.regularMaterial, in: .rect(cornerRadius: 10)).padding()
            }
        }
        .confirmationDialog("Remove this account from Kibble?", isPresented: Binding(
            get: { removingAccount != nil }, set: {
                if !$0 {
                    removingAccount = nil
                }
            }
        )) {
            Button("Remove Account", role: .destructive) {
                let id = removingAccount
                removingAccount = nil
                if let id {
                    Task { await host.removeAccount(id) }
                }
            }
        }
    }

    private func placeholder(_ workspace: AccountWorkspace) -> some View {
        VStack(spacing: 16) {
            if let account = workspace.accounts.first(where: { $0.id == workspace.selectedID }) {
                Text(account.label).font(.title2)
                if let error = workspace.accountErrors[account.id] {
                    Text(error)
                    Button("Retry") { Task { await host.retryAccount(account.id.rawValue) } }
                } else if !account.isEnabled {
                    Text("This account is disabled.").foregroundStyle(.secondary)
                    Button("Enable Account") {
                        Task { await host.setEnabled(true, account: account.id.rawValue) }
                    }
                } else if account.authenticationState != nil {
                    Text("This account needs to sign in again.")
                } else {
                    ProgressView("Connecting…")
                    Button("Retry Account") { Task { await host.retryAccount(account.id.rawValue) } }
                }
            } else {
                Text("Connect your accounts").font(.title2)
                Button("Add Demo Account") { Task { await host.addAccount() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
