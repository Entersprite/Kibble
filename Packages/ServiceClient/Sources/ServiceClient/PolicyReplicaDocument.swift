import ChatAPI
import ChatKit
import Foundation

/// A cache is valid only for this service, account and verified binding.
public struct PolicyReplicaBinding: Codable, Hashable, Sendable {
    public let service: ServiceInstanceID
    public let account: ConnectedAccountID
    public let revision: ServiceAccountRevision
    public let identity: Member.ID

    public init(
        service: ServiceInstanceID,
        account: ConnectedAccountID,
        revision: ServiceAccountRevision,
        identity: Member.ID
    ) {
        self.service = service; self.account = account; self.revision = revision; self.identity = identity
    }
}

public protocol PolicyReplicaStorage: Sendable {
    func load() throws -> PolicyReplicaDocument?
    func save(_ document: PolicyReplicaDocument) throws
}

public struct PolicyReplicaDocument: Codable, Hashable, Sendable {
    public let version: Int
    public let binding: PolicyReplicaBinding
    public internal(set) var acknowledged: AccountPolicy?
    var pending: [PolicyEdit]

    public init(binding: PolicyReplicaBinding) {
        version = 1; self.binding = binding; acknowledged = nil; pending = []
    }

    func validate(for binding: PolicyReplicaBinding) throws {
        guard version == 1, self.binding == binding, pending.count <= 4096,
              Set(pending.map(\.scope)).count == pending.count,
              try ServiceCodec.encode(self).count <= 2 * 1024 * 1024
        else { throw ServiceFailure.policyUnavailable }
        if let acknowledged {
            try Self.validate(acknowledged.settings)
        }
        _ = try effectiveSettings()
    }

    static func validate(_ settings: NotificationSettings) throws {
        guard settings.schemaVersion == NotificationSettings.currentSchemaVersion,
              Set(settings.records.map(\.scope)).count == settings.records.count,
              try ServiceCodec.encode(settings).count <= 1024 * 1024
        else { throw ServiceFailure.policyUnavailable }
    }

    func effectiveSettings() throws -> NotificationSettings {
        var settings = acknowledged?.settings ?? NotificationSettings()
        for edit in pending {
            try edit.apply(to: &settings)
        }
        try Self.validate(settings)
        return settings
    }
}

struct PolicyFieldEdit: Codable, Hashable, Sendable {
    let key: String
    let removes: Bool
    let value: JSONValue
}

enum PolicyValueEdit: Codable, Hashable, Sendable {
    case rule([PolicyFieldEdit])
    case value(SettingsValue)
}

struct PolicyEdit: Codable, Hashable, Sendable {
    let scope: SettingsScope
    var change: PolicyValueEdit
    var modifiedAt: Date
    var modifiedBy: String

    func apply(to settings: inout NotificationSettings) throws {
        let old = settings.record(for: scope)
        let value: SettingsValue
        switch change {
        case let .rule(fields):
            if let old, case .rule = old.value {} else if old != nil {
                throw ServiceFailure.policyUnavailable
            }
            var object = try Self.fields(old?.value)
            for field in fields {
                object[field.key] = field.removes ? nil : field.value
            }
            value = try .rule(ServiceCodec.decode(NotificationRule.self, from: .object(object)))
        case let .value(replacement):
            if let old, case .unknown = old.value {
                throw ServiceFailure.policyUnavailable
            }
            value = replacement
        }
        let record = SettingsRecord(
            scope: scope,
            value: value,
            modifiedAt: modifiedAt,
            modifiedBy: modifiedBy
        )
        if let index = settings.records.firstIndex(where: { $0.scope == scope }) {
            settings.records[index] = record
        } else {
            settings.records.append(record)
        }
    }

    func isFulfilled(by settings: NotificationSettings) throws -> Bool {
        switch change {
        case let .rule(fields):
            if let record = settings.record(for: scope), case .rule = record.value {} else {
                return false
            }
            let object = try Self.fields(settings.record(for: scope)?.value)
            return fields.allSatisfy { object[$0.key] == ($0.removes ? nil : $0.value) }
        case let .value(value): return settings.record(for: scope)?.value == value
        }
    }

    static func fields(_ value: SettingsValue?) throws -> [String: JSONValue] {
        guard let value else { return [:] }
        guard case let .rule(rule) = value,
              case let .object(fields) = try ServiceCodec.value(rule)
        else { throw ServiceFailure.policyUnavailable }
        return fields
    }
}
