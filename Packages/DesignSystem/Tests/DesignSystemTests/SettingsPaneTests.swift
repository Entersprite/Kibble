import Testing
@testable import DesignSystem

/// Settings reopens on the kept pane, and a kept pane that is no longer drawn
/// opens the one that holds its settings now, never an empty selection.
struct SettingsPaneTests {
    private let shared: [SettingsPane] = [.notifications, .calls, .sidebar, .downloads, .updates]
    private var accountHost: [SettingsPane] {
        [.accounts] + shared
    }

    private var singleSession: [SettingsPane] {
        shared + [.account]
    }

    @Test func aShownPaneIsKept() {
        for pane in accountHost {
            #expect(SettingsPane.resolve(pane.rawValue, shown: accountHost) == pane)
        }
        for pane in singleSession {
            #expect(SettingsPane.resolve(pane.rawValue, shown: singleSession) == pane)
        }
    }

    @Test func conversationsOpensNotificationsWhereItsRulesNowAre() {
        #expect(SettingsPane.resolve("conversations", shown: accountHost) == .notifications)
        #expect(SettingsPane.resolve("conversations", shown: singleSession) == .notifications)
    }

    @Test func accountAndAccountsStandInForEachOther() {
        #expect(SettingsPane.resolve("account", shown: accountHost) == .accounts)
        #expect(SettingsPane.resolve("accounts", shown: singleSession) == .account)
    }

    /// Under the account host before its accounts load, neither account pane is drawn.
    @Test func anAccountPaneWithNeitherShownFallsBackToNotifications() {
        let starting: [SettingsPane] = [.notifications, .calls, .sidebar, .downloads, .updates]
        #expect(SettingsPane.resolve("account", shown: starting) == .notifications)
        #expect(SettingsPane.resolve("accounts", shown: starting) == .notifications)
    }

    @Test func anUnknownOrEmptyValueFallsBackToNotifications() {
        #expect(SettingsPane.resolve("", shown: accountHost) == .notifications)
        #expect(SettingsPane.resolve("general", shown: accountHost) == .notifications)
    }

    /// The values the shell writes to deep-link a pane resolve to that pane.
    @Test func theShellsDeepLinksStillResolve() {
        #expect(SettingsPane.resolve("accounts", shown: accountHost) == .accounts)
        #expect(SettingsPane.resolve("sidebar", shown: accountHost) == .sidebar)
        #expect(SettingsPane.resolve("notifications", shown: singleSession) == .notifications)
    }
}

struct SettingsPaneCopyTests {
    @Test func theConversationsRowCountsCustomizedConversations() {
        #expect(ConversationRuleList.summary(count: 0) == "None")
        #expect(ConversationRuleList.summary(count: 1) == "1 Custom")
        #expect(ConversationRuleList.summary(count: 12) == "12 Custom")
    }

    @Test func accountStatusesReadAsBefore() {
        let statuses: [AccountPanelAccount.Status] = [
            .connected, .connecting, .disabled, .signedOut, .failed, .removing
        ]
        #expect(statuses.map(AccountsSettingsStatus.title(of:)) == [
            "Connected", "Connecting…", "Disabled", "Signed out", "Could not connect", "Removing…"
        ])
    }
}
