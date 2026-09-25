import Foundation

/// One account's notification settings: a list of stamped records, one per
/// scope (spec §2.2).
///
/// **Records, not one document, because of sync.** Two devices editing
/// different scopes merge instead of the later one clobbering the earlier.
/// **Clearing never deletes** - `setRule(NotificationRule(), …)` leaves an
/// emptied, restamped record, which wins a future merge without tombstones.
/// The merge itself is not built (spec §2.2, "not built now").
public struct NotificationSettings: Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var records: [SettingsRecord]

    public init(records: [SettingsRecord] = [], schemaVersion: Int = currentSchemaVersion) {
        self.records = records
        self.schemaVersion = schemaVersion
    }
}

/// One scope's value, stamped with when and where it was last changed.
public struct SettingsRecord: Hashable, Sendable {
    public var scope: SettingsScope
    public var value: SettingsValue
    public var modifiedAt: Date
    /// A per-install device id - the tie-break a future merge will use.
    public var modifiedBy: String

    public init(scope: SettingsScope, value: SettingsValue, modifiedAt: Date, modifiedBy: String) {
        self.scope = scope
        self.value = value
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
    }
}

public extension NotificationSettings {
    func record(for scope: SettingsScope) -> SettingsRecord? {
        records.first { $0.scope == scope }
    }

    func rule(for scope: SettingsScope) -> NotificationRule? {
        guard case let .rule(rule)? = record(for: scope)?.value else { return nil }
        return rule
    }

    /// Replaces the scope's record, or appends one. Never removes one.
    mutating func setRule(
        _ rule: NotificationRule,
        for scope: SettingsScope,
        at date: Date,
        by device: String
    ) {
        let record = SettingsRecord(scope: scope, value: .rule(rule), modifiedAt: date, modifiedBy: device)
        if let index = records.firstIndex(where: { $0.scope == scope }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    /// The chain `[conversation, section, section preset, global, built-in]`.
    func resolve(for conversation: Conversation) -> ResolvedRule {
        let section = SectionKey(kind: conversation.kind).ruleSection
        let own = rule(for: .conversation(conversation.id)).map { [$0] } ?? []
        return NotificationRule.resolve(own + chain(forSection: section))
    }

    var resolvedGlobal: ResolvedRule {
        NotificationRule.resolve(rule(for: .global).map { [$0] } ?? [])
    }

    /// What a section resolves to, its own record included.
    func resolvedSection(_ section: SectionKey) -> ResolvedRule {
        NotificationRule.resolve(chain(forSection: section))
    }

    /// What a section falls back to when its own record says nothing - the
    /// value its editor shows as "Default (…)".
    func inherited(bySection section: SectionKey) -> ResolvedRule {
        NotificationRule.resolve(chain(belowSection: section))
    }

    /// Unread conversations whose rule counts them (spec §3). Conversations,
    /// not messages: Google sends every unread count as 0 (`findings.md` §37.8).
    func badgeCount(of conversations: [Conversation]) -> Int {
        conversations.count { $0.hasUnread && resolve(for: $0).countsInBadge }
    }

    private func chain(forSection section: SectionKey) -> [NotificationRule] {
        (rule(for: .section(section)).map { [$0] } ?? []) + chain(belowSection: section)
    }

    private func chain(belowSection section: SectionKey) -> [NotificationRule] {
        let preset = section == .meetChats ? [NotificationRule.meetChatsPreset] : []
        return preset + (rule(for: .global).map { [$0] } ?? [])
    }
}
