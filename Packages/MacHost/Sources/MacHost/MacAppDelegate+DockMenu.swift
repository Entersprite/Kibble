import AppCore
import AppKit
import ChatAPI

/// The Dock icon's menu while several accounts are connected: each account
/// with its unread count, the one on screen checked. Choosing one shows it,
/// as a notification click does.
extension MacAppDelegate {
    public func applicationDockMenu(_: NSApplication) -> NSMenu? {
        guard let workspace = accountHost?.workspace, workspace.accounts.count > 1 else { return nil }
        let labels = workspace.accountLabels
        let menu = NSMenu()
        for account in workspace.accounts {
            let label = labels[account.id] ?? account.label
            let unread = workspace.environment(for: account.id)?.badgeCount ?? 0
            let item = NSMenuItem(
                title: unread > 0 ? "\(label) (\(unread))" : label,
                action: #selector(showDockMenuAccount(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account.id.rawValue
            item.state = account.id == workspace.selectedID ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showDockMenuAccount(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        accountHost?.workspace?.showAccount(ConnectedAccountID(id))
    }
}
