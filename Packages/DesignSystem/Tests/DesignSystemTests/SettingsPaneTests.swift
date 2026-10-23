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

    /// Every outcome says what happened, and the ones that need a change name
    /// where to make it; none names a provider.
    @Test func aTestNotificationSaysWhatTheSystemAllowed() {
        let outcomes: [NotificationTestOutcome] = [
            .sent, .withoutSound, .withoutBanner, .quiet, .notAllowed, .failed
        ]
        let messages = outcomes.map(\.message)
        #expect(Set(messages).count == outcomes.count)
        #expect(messages.allSatisfy { !$0.isEmpty && !$0.contains("Google") })
        for outcome in [NotificationTestOutcome.withoutSound, .withoutBanner, .quiet, .notAllowed] {
            #expect(outcome.message.contains("System Settings"))
        }
        #expect(NotificationTestOutcome.notAllowed.message
            == "Notifications are off for Kibble. Turn them on in System Settings.")
        #expect(NotificationTestOutcome.sent.message.contains("Focus"))
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
