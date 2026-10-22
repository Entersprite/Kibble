import ChatKit
import SwiftUI

/// Values in, callbacks out - the `ChatSceneState` pattern, for Settings.
public struct NotificationSettingsState: Equatable, Sendable {
    /// `false` until an account is identified: rules belong to an account.
    public var isAvailable: Bool
    /// The global record as saved (fields may be `nil`) and what it resolves to.
    public var globalRule: NotificationRule
    public var global: ResolvedRule
    public var inheritedGlobal: ResolvedRule = .builtIn
    public var editsSharedDefaults = false
    public var sections: [SectionKey: NotificationRule]
    /// What each section falls back to - its "Default (…)" values.
    public var sectionInherited: [SectionKey: ResolvedRule]
    public var sectionResolved: [SectionKey: ResolvedRule]
    public var lastError: String?
    /// The status line under "Pause notifications". `nil` when not paused.
    public var pauseStatus: String?
    /// The pause is this Mac's, not the account's, and several accounts are
    /// connected: the pane, which edits one account, says so.
    public var pauseIsShared = false
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
    public var reset: (() -> Void)?
    public var updateGlobal: (NotificationRule) -> Void
    public var updateSection: (SectionKey, NotificationRule) -> Void
    /// `nil` hides the row - `CLAUDE.md`: never draw a control the host cannot honor.
    public var openSystemSettings: (() -> Void)?
    public var pause: (PauseDuration) -> Void
    public var resume: () -> Void
    public var updateConversation: (Conversation.ID, NotificationRule) -> Void

    public init(
        reset: (() -> Void)? = nil,
        updateGlobal: @escaping (NotificationRule) -> Void = { _ in },
        updateSection: @escaping (SectionKey, NotificationRule) -> Void = { _, _ in },
        openSystemSettings: (() -> Void)? = nil,
        pause: @escaping (PauseDuration) -> Void = { _ in },
        resume: @escaping () -> Void = {},
        updateConversation: @escaping (Conversation.ID, NotificationRule) -> Void = { _, _ in }
    ) {
        self.reset = reset
        self.updateGlobal = updateGlobal
        self.updateSection = updateSection
        self.openSystemSettings = openSystemSettings
        self.pause = pause
        self.resume = resume
        self.updateConversation = updateConversation
    }
}

/// A section row's one-line summary: what it resolves to, whether only
/// mentions notify, whether its unread indicator is hidden, and whether it
/// has its own record.
public enum RuleSummary {
    public static func describe(rule: NotificationRule, resolved: ResolvedRule) -> String {
        var parts = [Display.title(of: resolved.delivery)]
        if resolved.delivery != .off, resolved.notifyAbout == .mentions {
            parts.append(Display.title(of: NotifyChoice.mentions))
        }
        if !resolved.showsUnread {
            parts.append("Unread hidden")
        }
        if !rule.isEmpty {
            parts.append("Custom")
        }
        return parts.joined(separator: " · ")
    }
}

/// The Notifications pane, modeled on System Settings › Notifications: the
/// defaults, then the sections and the conversations with their own
/// settings, each drilling in (spec §4).
public struct NotificationSettingsPane: View {
    private let state: NotificationSettingsState
    private let actions: NotificationSettingsActions
    @State private var navigationScope = UUID()
    @State private var isVisible = false
    @State private var path: [NotificationSettingsPage] = []
    @State private var navigationFocus: NotificationSettingsFocus?
    @FocusState private var focus: NotificationSettingsFocus?

    public init(state: NotificationSettingsState, actions: NotificationSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                SettingsScopeHeader {}
                root
            }
            .notificationPage(isActive: path.isEmpty)
            ForEach(path, id: \.self) { page in
                VStack(spacing: 0) {
                    NotificationPageHeader(
                        page: page, title: page.title(in: state), focus: $focus
                    ) {
                        goBack()
                    }
                    destination(page)
                }
                .notificationPage(isActive: path.last == page)
            }
        }
        .navigationTitle("Notifications")
        .task(id: path) { focus = navigationFocus }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .focusedSceneValue(
            \.notificationSettingsBack,
            isVisible && !path.isEmpty
                ? NotificationSettingsBackAction(scope: navigationScope, path: path, perform: goBack) : nil
        )
    }

    private var root: some View {
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
            if !state.editsSharedDefaults {
                sections.disabled(!state.isAvailable)
                conversations.disabled(!state.isAvailable)
            }
            if let open = actions.openSystemSettings {
                Section {
                    Button("Open Notification Settings…", action: open)
                } footer: {
                    Text("Banner or alert style is set in System Settings.")
                }
            }
            if let reset = actions.reset {
                Section {
                    SettingsResetButton(
                        message: resetMessage,
                        action: reset
                    )
                    .disabled(!state.isAvailable)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func destination(_ page: NotificationSettingsPage) -> some View {
        switch page {
        case let .section(section):
            NotificationRuleEditor(
                title: Display.title(of: section),
                rule: state.sections[section] ?? NotificationRule(),
                inherited: state.sectionInherited[section] ?? state.global,
                update: { actions.updateSection(section, $0) }
            ).form
        case .conversations:
            ConversationRuleList(state: state, focus: $focus) { open(.conversation($0)) }
        case let .conversation(id):
            ConversationRuleDestination(state: state, actions: actions, id: id)
        }
    }

    private func open(_ page: NotificationSettingsPage) {
        navigationFocus = .back(page)
        path.append(page)
    }

    private func goBack() {
        guard let page = path.popLast() else { return }
        navigationFocus = .link(page)
    }

    private var resetMessage: String {
        let scope = state.editsSharedDefaults
            ? "Reset global notification defaults? Account, group, and conversation overrides are kept."
            : "Reset all notification settings for this account, including group and conversation overrides?"
        return scope + " This cannot be undone."
    }

    /// One row for every conversation with its own settings, as System
    /// Settings › Notifications lists apps; the list is a level down, so a
    /// long one never pushes the defaults off the pane.
    private var conversations: some View {
        Section {
            NotificationPageLink(
                title: "Conversations",
                summary: ConversationRuleList.summary(count: state.conversations.count)
            ) { open(.conversations) }
                .focused($focus, equals: .link(.conversations))
        } footer: {
            Text("Conversations with their own settings. Right-click one in the sidebar to change it.")
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
        } footer: {
            if state.pauseIsShared {
                Text("Pausing applies to every account on this Mac.")
            }
        }
    }

    private var defaults: some View {
        NotificationRuleFields(
            title: "Defaults", rule: state.globalRule, inherited: state.inheritedGlobal,
            allowsInheritance: !state.editsSharedDefaults, update: actions.updateGlobal
        )
    }

    private var sections: some View {
        Section {
            ForEach(SectionKey.ruleSections, id: \.self) { section in
                NotificationPageLink(
                    title: Display.title(of: section),
                    summary: RuleSummary.describe(
                        rule: state.sections[section] ?? NotificationRule(),
                        resolved: state.sectionResolved[section] ?? state.global
                    )
                ) { open(.section(section)) }
                    .focused($focus, equals: .link(.section(section)))
            }
        } header: {
            Text("Sections")
        } footer: {
            Text("Other also covers conversation types this version of Kibble doesn’t recognize.")
        }
    }
}
