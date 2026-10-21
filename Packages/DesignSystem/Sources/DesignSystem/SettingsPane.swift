/// The Settings window's panes, by the identifier the shell keeps so that
/// Settings reopens on the last pane (HIG).
///
/// A kept identifier can name a pane this launch does not show: one that was
/// folded into another (Conversations went into Notifications), or the
/// single-session Account pane under the account host, where Accounts took
/// it over. `resolve` turns any kept value into a pane that is shown, so the
/// window never opens on an empty selection.
public enum SettingsPane: String, CaseIterable, Sendable {
    case accounts
    case notifications
    case calls
    case sidebar
    case downloads
    case updates
    /// The single session's own account, without the account host.
    case account

    /// The pane that shows `stored`'s settings among `shown`; Notifications,
    /// which every configuration shows, when nothing closer is.
    public static func resolve(_ stored: String, shown: [SettingsPane]) -> SettingsPane {
        let candidates: [SettingsPane] = switch stored {
        // Per-conversation rules are a row in Notifications now.
        case "conversations": [.notifications]
        // One account's pane and every account's pane stand in for each other.
        case Self.account.rawValue: [.account, .accounts]
        case Self.accounts.rawValue: [.accounts, .account]
        default: Self(rawValue: stored).map { [$0] } ?? []
        }
        return candidates.first(where: shown.contains) ?? .notifications
    }
}
