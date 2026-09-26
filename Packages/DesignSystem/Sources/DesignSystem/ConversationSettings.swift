import ChatKit
import SwiftUI

/// One conversation's rule, as its editor and the Conversations pane draw it.
public struct ConversationRuleState: Equatable, Sendable, Identifiable {
    public var id: Conversation.ID
    /// The sidebar's title, or "Unavailable conversation" for one with a
    /// record that is not listed (left, or not loaded yet).
    public var title: String
    public var rule: NotificationRule
    /// Its "Default (…)" values: the chain without its own record.
    public var inherited: ResolvedRule
    public var resolved: ResolvedRule
    /// What the editor's "Notify about" writes as delivery when a choice would
    /// otherwise stay Off: the global delivery unless that is Off, else
    /// Banner and sound (plan ruling 5). The host computes it.
    public var audibleFallback: Delivery

    public init(
        id: Conversation.ID, title: String, rule: NotificationRule,
        inherited: ResolvedRule, resolved: ResolvedRule,
        audibleFallback: Delivery = .bannerAndSound
    ) {
        self.id = id
        self.title = title
        self.rule = rule
        self.inherited = inherited
        self.resolved = resolved
        self.audibleFallback = audibleFallback
    }
}

/// Which conversation's sheet is up - `sheet(item:)` needs an `Identifiable`.
public struct ConversationSelection: Identifiable, Hashable, Sendable {
    public let id: Conversation.ID

    public init(id: Conversation.ID) {
        self.id = id
    }
}

/// "Notifications for <name>", with a Done button (spec §4, the main window).
public struct ConversationNotificationSheet: View {
    private let state: ConversationRuleState
    private let update: (NotificationRule) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(state: ConversationRuleState, update: @escaping (NotificationRule) -> Void) {
        self.state = state
        self.update = update
    }

    public var body: some View {
        NavigationStack {
            NotificationRuleEditor(
                title: "Notifications for \(state.title)",
                rule: state.rule, inherited: state.inherited,
                audibleFallback: state.audibleFallback, update: update
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // `[Verify]` in the running app, like every pane's size.
        .frame(minWidth: 460, minHeight: 360)
    }
}

/// Every conversation with its own settings, with Reset, drilling in to the
/// same editor (spec §4, Conversations pane).
public struct ConversationSettingsPane: View {
    private let state: NotificationSettingsState
    private let actions: NotificationSettingsActions

    /// Split from the `Text` call so the line stays under lint's 110-column
    /// limit rather than disabling the rule.
    private let emptyStateMessage = "No conversation has its own notification settings. "
        + "Right-click one in the sidebar to change it."

    public init(state: NotificationSettingsState, actions: NotificationSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        NavigationStack {
            Form {
                if state.conversations.isEmpty {
                    Text(emptyStateMessage)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(state.conversations) { conversation in
                            HStack {
                                NavigationLink(value: conversation.id) {
                                    LabeledContent(conversation.title) {
                                        Text(RuleSummary.describe(
                                            rule: conversation.rule, resolved: conversation.resolved
                                        ))
                                    }
                                }
                                Button("Reset") {
                                    actions.updateConversation(conversation.id, NotificationRule())
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!state.isAvailable)
            .navigationDestination(for: Conversation.ID.self) { id in
                // Reset from inside the editor empties the record, and the
                // row leaves the list; say so rather than draw nothing.
                if let conversation = state.conversations.first(where: { $0.id == id }) {
                    NotificationRuleEditor(
                        title: conversation.title, rule: conversation.rule,
                        inherited: conversation.inherited,
                        audibleFallback: conversation.audibleFallback,
                        update: { actions.updateConversation(id, $0) }
                    )
                } else {
                    ContentUnavailableView(
                        "Back to defaults",
                        systemImage: "bell.slash",
                        description: Text("This conversation now follows its section’s settings.")
                    )
                }
            }
        }
    }
}
