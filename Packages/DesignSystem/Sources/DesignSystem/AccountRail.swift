import SwiftUI

public struct AccountRailItem: Identifiable {
    public let id: String
    public let label: String
    public let badge: Int
    public let isEnabled: Bool
    public let hasIssue: Bool

    public init(id: String, label: String, badge: Int, isEnabled: Bool, hasIssue: Bool) {
        self.id = id; self.label = label; self.badge = badge
        self.isEnabled = isEnabled; self.hasIssue = hasIssue
    }
}

public struct AccountRail: View {
    private let accounts: [AccountRailItem]
    private let selected: String?
    private let select: (String) -> Void
    private let toggle: (AccountRailItem) -> Void
    private let remove: (String) -> Void
    private let add: () -> Void
    private let simulateMessage: ((String) -> Void)?

    public init(
        accounts: [AccountRailItem], selected: String?, select: @escaping (String) -> Void,
        toggle: @escaping (AccountRailItem) -> Void, remove: @escaping (String) -> Void,
        add: @escaping () -> Void, simulateMessage: ((String) -> Void)? = nil
    ) {
        self.accounts = accounts; self.selected = selected; self.select = select; self.toggle = toggle
        self.remove = remove; self.add = add; self.simulateMessage = simulateMessage
    }

    public var body: some View {
        VStack(spacing: 14) {
            ScrollView {
                VStack(spacing: 14) { ForEach(accounts) { account in accountButton(account) } }
                    .padding(.vertical, 16)
            }
            Button(action: add) { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44) }
                .buttonStyle(.plain)
                .help("Add account")
                .accessibilityLabel("Add account")
                .padding(.bottom, 16)
        }
        .frame(width: 72)
        .background(.ultraThinMaterial)
    }

    private func accountButton(_ account: AccountRailItem) -> some View {
        Button { select(account.id) } label: {
            Text(String(account.label.prefix(1)).uppercased())
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(
                    selected == account.id ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                    in: .rect(cornerRadius: 14)
                )
                .overlay(alignment: .bottomTrailing) {
                    if account.badge > 0 {
                        Text(account.badge > 99 ? "99+" : String(account.badge))
                            .font(.caption2.weight(.bold)).padding(.horizontal, 4)
                            .background(.red, in: .capsule).foregroundStyle(.white).offset(x: 5, y: 5)
                    } else if account.hasIssue {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).offset(
                            x: 4,
                            y: 4
                        )
                    }
                }
                .opacity(account.isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .help(account.label)
        .accessibilityLabel(account.label)
        .accessibilityAddTraits(selected == account.id ? .isSelected : [])
        .contextMenu {
            Button(account.isEnabled ? "Disable Account" : "Enable Account") { toggle(account) }
            if let simulateMessage {
                Button("Simulate Message") { simulateMessage(account.id) }
            }
            Divider()
            Button("Remove Account…", role: .destructive) { remove(account.id) }
        }
    }
}
