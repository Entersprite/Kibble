import ChatKit
import SwiftUI

/// Values in, callbacks out - the `ChatSceneState` pattern, for Settings.
public struct NotificationSettingsState: Equatable, Sendable {
    /// `false` until an account is identified: rules belong to an account.
    public var isAvailable: Bool
    /// The global record as saved (fields may be `nil`) and what it resolves to.
    public var globalRule: NotificationRule
    public var global: ResolvedRule
    public var sections: [SectionKey: NotificationRule]
    /// What each section falls back to - its "Default (…)" values.
    public var sectionInherited: [SectionKey: ResolvedRule]
    public var sectionResolved: [SectionKey: ResolvedRule]
    public var lastError: String?
    /// The status line under "Pause notifications". `nil` when not paused.
    public var pauseStatus: String?
    public var conversations: [ConversationRuleState]

    public init(
        isAvailable: Bool = false,
        globalRule: NotificationRule = NotificationRule(),
        global: ResolvedRule = .builtIn,
        sections: [SectionKey: NotificationRule] = [:],
        sectionInherited: [SectionKey: ResolvedRule] = [:],
        sectionResolved: [SectionKey: ResolvedRule] = [:],
        lastError: String? = nil,
        pauseStatus: String? = nil,
        conversations: [ConversationRuleState] = []
    ) {
        self.isAvailable = isAvailable
        self.globalRule = globalRule
        self.global = global
        self.sections = sections
        self.sectionInherited = sectionInherited
        self.sectionResolved = sectionResolved
        self.lastError = lastError
        self.pauseStatus = pauseStatus
        self.conversations = conversations
    }
}

@MainActor
public struct NotificationSettingsActions {
    public var updateGlobal: (NotificationRule) -> Void
    public var updateSection: (SectionKey, NotificationRule) -> Void
    /// `nil` hides the button - `CLAUDE.md`: never draw a control the host cannot honour.
    public var openSystemSettings: (() -> Void)?
    public var pause: (PauseDuration) -> Void
    public var resume: () -> Void
    public var updateConversation: (Conversation.ID, NotificationRule) -> Void

    public init(
        updateGlobal: @escaping (NotificationRule) -> Void = { _ in },
        updateSection: @escaping (SectionKey, NotificationRule) -> Void = { _, _ in },
        openSystemSettings: (() -> Void)? = nil,
        pause: @escaping (PauseDuration) -> Void = { _ in },
        resume: @escaping () -> Void = {},
        updateConversation: @escaping (Conversation.ID, NotificationRule) -> Void = { _, _ in }
    ) {
        self.updateGlobal = updateGlobal
        self.updateSection = updateSection
        self.openSystemSettings = openSystemSettings
        self.pause = pause
        self.resume = resume
        self.updateConversation = updateConversation
    }
}

/// A section row's one-line summary: what it resolves to, whether its unread
/// indicator is hidden, and whether it has its own record.
public enum RuleSummary {
    public static func describe(rule: NotificationRule, resolved: ResolvedRule) -> String {
        var parts = [Display.title(of: resolved.delivery)]
        if !resolved.showsUnread {
            parts.append("Unread hidden")
        }
        if !rule.isEmpty {
            parts.append("Custom")
        }
        return parts.joined(separator: " · ")
    }
}

/// The Notifications pane, modelled on System Settings › Notifications: the
/// defaults, then a section list that drills in (spec §4).
public struct NotificationSettingsPane: View {
    private let state: NotificationSettingsState
    private let actions: NotificationSettingsActions

    public init(state: NotificationSettingsState, actions: NotificationSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let lastError = state.lastError {
                    Section {
                        Label(lastError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                if !state.isAvailable {
                    Section {
                        Text("Sign in to change notification settings. They’re kept per account.")
                            .foregroundStyle(.secondary)
                    }
                }
                pause
                    .disabled(!state.isAvailable)
                defaults
                    .disabled(!state.isAvailable)
                sections
                    .disabled(!state.isAvailable)
                Section {} footer: {
                    HStack {
                        Text("Banner or alert style is set in System Settings.")
                        if let open = actions.openSystemSettings {
                            Button("Open Notification Settings…", action: open)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationDestination(for: SectionKey.self) { section in
                NotificationRuleEditor(
                    title: Display.title(of: section),
                    rule: state.sections[section] ?? NotificationRule(),
                    inherited: state.sectionInherited[section] ?? state.global,
                    update: { actions.updateSection(section, $0) }
                )
            }
        }
    }

    /// Spec §4.1: a pop-up while not paused; the status and Resume while paused.
    private var pause: some View {
        Section {
            if let status = state.pauseStatus {
                LabeledContent(status) {
                    Button("Resume", action: actions.resume)
                }
            } else {
                Picker("Pause notifications", selection: Binding<PauseDuration?>(
                    get: { nil },
                    set: {
                        if let duration = $0 {
                            actions.pause(duration)
                        }
                    }
                )) {
                    Text("Off").tag(PauseDuration?.none)
                    ForEach(PauseDuration.allCases, id: \.self) {
                        Text(Display.title(of: $0)).tag(PauseDuration?.some($0))
                    }
                }
            }
        }
    }

    private var defaults: some View {
        Section("Defaults") {
            Picker("Deliver as", selection: Binding(
                get: { state.global.delivery },
                set: { value in
                    var rule = state.globalRule
                    rule.delivery = value
                    actions.updateGlobal(rule)
                }
            )) {
                ForEach(Delivery.choices, id: \.self) { Text(Display.title(of: $0)).tag($0) }
            }
            Toggle("Show message previews", isOn: global(\.showsPreview, \.showsPreview))
            Toggle("Show unread indicator", isOn: global(\.showsUnread, \.showsUnread))
            Toggle("Count in Dock badge", isOn: global(\.countsInBadge, \.countsInBadge))
            Toggle("Send read receipts", isOn: global(\.readReceipts, \.readReceipts))
        }
    }

    private var sections: some View {
        Section {
            ForEach(SectionKey.ruleSections, id: \.self) { section in
                NavigationLink(value: section) {
                    LabeledContent(Display.title(of: section)) {
                        Text(RuleSummary.describe(
                            rule: state.sections[section] ?? NotificationRule(),
                            resolved: state.sectionResolved[section] ?? state.global
                        ))
                    }
                }
            }
        } header: {
            Text("Sections")
        } footer: {
            Text("Other also covers conversation types this version of GChat doesn’t recognise.")
        }
    }

    private func global(
        _ resolved: KeyPath<ResolvedRule, Bool>,
        _ field: WritableKeyPath<NotificationRule, Bool?>
    ) -> Binding<Bool> {
        Binding(
            get: { state.global[keyPath: resolved] },
            set: { value in
                var rule = state.globalRule
                rule[keyPath: field] = value
                actions.updateGlobal(rule)
            }
        )
    }
}

/// One level's five settings, each defaulting to what it inherits. Used for a
/// section here, and for a conversation by `ConversationNotificationSheet`
/// and `ConversationSettingsPane`.
public struct NotificationRuleEditor: View {
    private let title: String
    private let rule: NotificationRule
    private let inherited: ResolvedRule
    private let update: (NotificationRule) -> Void

    public init(
        title: String, rule: NotificationRule, inherited: ResolvedRule,
        update: @escaping (NotificationRule) -> Void
    ) {
        self.title = title
        self.rule = rule
        self.inherited = inherited
        self.update = update
    }

    public var body: some View {
        Form {
            Section {
                Picker("Deliver as", selection: Binding(
                    get: { rule.delivery },
                    set: { value in
                        var changed = rule
                        changed.delivery = value
                        update(changed)
                    }
                )) {
                    Text("Default (\(Display.title(of: inherited.delivery)))").tag(Delivery?.none)
                    ForEach(Delivery.choices, id: \.self) {
                        Text(Display.title(of: $0)).tag(Delivery?.some($0))
                    }
                }
                choice("Show message previews", \.showsPreview, inherited.showsPreview)
                choice("Show unread indicator", \.showsUnread, inherited.showsUnread)
                choice("Count in Dock badge", \.countsInBadge, inherited.countsInBadge)
                choice("Send read receipts", \.readReceipts, inherited.readReceipts)
            }
            Section {
                Button("Reset to Defaults") { update(NotificationRule()) }
                    .disabled(rule.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }

    private func choice(
        _ label: String,
        _ field: WritableKeyPath<NotificationRule, Bool?>,
        _ fallback: Bool
    ) -> some View {
        Picker(label, selection: Binding(
            get: { rule[keyPath: field] },
            set: { value in
                var changed = rule
                changed[keyPath: field] = value
                update(changed)
            }
        )) {
            Text("Default (\(fallback ? "On" : "Off"))").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
    }
}
