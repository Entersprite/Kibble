import ChatKit
import SwiftUI

/// Your avatar and name, and with several accounts which one this is. Closed,
/// a badge says another account needs you.
struct AccountPill: View {
    let state: AccountPanelState
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if state.showsLabels, let label = state.selected?.label {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if !isOpen {
                    if state.othersHaveProblem {
                        AccountIssueBadge(size: 16)
                    } else if state.othersUnread > 0 {
                        AccountCountBadge(count: state.othersUnread)
                    }
                }
            }
            .padding(.leading, AccountPanelLayout.avatarInset)
            .padding(.trailing, 12)
            .frame(height: AccountPanelLayout.controlSize)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Close" : "Your status and accounts")
        .accessibilityLabel(state.showsLabels ? "\(name), \(state.selected?.label ?? "")" : name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows your status and accounts")
    }

    private var name: String {
        if let scene = state.scene {
            return Display.signedInLabel(me: scene.me, directory: scene.directory)
        }
        return state.selected?.name ?? state.selected?.label ?? "Account"
    }

    private var accessibilityValue: String {
        if state.othersHaveProblem {
            return "Another account needs to sign in"
        }
        return state.othersUnread > 0 ? "\(state.othersUnread) unread in other accounts" : ""
    }

    @ViewBuilder private var avatar: some View {
        let size = AccountPanelLayout.avatarSize
        if let scene = state.scene, let me = scene.me {
            Avatar(
                member: me, directory: scene.directory, size: size,
                presence: Display.ownPresence(
                    availability: scene.availability, directory: scene.directory, me: me,
                    connection: scene.connection, now: .now
                )
            )
            .environment(\.sceneImageLoader, state.selected?.imageLoader)
        } else if let account = state.selected {
            Avatar(member: account.me, directory: account.directory, size: size)
                .environment(\.sceneImageLoader, account.imageLoader)
        } else {
            UnknownPersonGlyph(size: size)
        }
    }
}

// MARK: - Status

/// Your availability and custom status, as the old account menu had them, for
/// the selected account. Choosing one closes the panel, as a menu would.
struct AccountStatusSection: View {
    let scene: ChatSceneState
    /// Which account the status belongs to; `nil` with only one.
    let label: String?
    let actions: AccountPanelActions
    let close: () -> Void
    let editStatus: () -> Void
    @State private var hoveringDoNotDisturb = false

    var body: some View {
        let model = StatusMenuModel(
            availability: scene.availability, status: AccountFooterOverlay.status(scene), now: .now
        )
        VStack(alignment: .leading, spacing: 1) {
            AccountPanelHeader(title: "Status", detail: label)
            AccountPanelRow(title: "Automatic", checked: model.isAutomatic) { set(.automatic) }
            Menu {
                ForEach(model.doNotDisturbChoices, id: \.self) { choice in
                    Button(choice.title) {
                        // Counted from the click, not from when the panel was drawn.
                        if let until = choice.until(now: .now, calendar: .current) {
                            set(.doNotDisturb(until: until))
                        }
                    }
                }
            } label: {
                AccountPanelRowLabel(
                    title: model.doNotDisturbTitle, checked: model.isDoNotDisturb, chevron: true,
                    hovered: hoveringDoNotDisturb
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { hoveringDoNotDisturb = $0 }
            AccountPanelRow(title: "Set as away", checked: model.isAway) { set(.away) }
            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
            if let line = model.statusLine {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
            }
            AccountPanelRow(title: "Set a Status…") {
                close()
                editStatus()
            }
            if model.statusLine != nil {
                AccountPanelRow(title: "Clear Status") {
                    close()
                    actions.setStatus?(nil)
                }
            }
        }
    }

    private func set(_ availability: Availability) {
        close()
        actions.setAvailability?(availability)
    }
}

struct AccountPanelHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(title).fontWeight(.semibold)
            if let detail {
                Text("·")
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct AccountPanelRow: View {
    let title: String
    var checked = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            AccountPanelRowLabel(title: title, checked: checked, chevron: false, hovered: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

struct AccountPanelRowLabel: View {
    let title: String
    let checked: Bool
    let chevron: Bool
    let hovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(checked ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .contentShape(.rect)
        .background(hovered ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
    }
}

// MARK: - Badges

struct AccountCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(.red))
            .accessibilityHidden(true)
    }
}

/// Drawn as a shape and a mark, so it does not rely on its color alone.
struct AccountIssueBadge: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: size * 0.55, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(.orange))
            .accessibilityHidden(true)
    }
}
