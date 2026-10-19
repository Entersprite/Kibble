import ChatAPI
import ChatKit
import Foundation

extension PolicyReplicaDocument {
    mutating func update(with input: NotificationSettings) throws {
        // Diff the same timestamp precision that the service acknowledges.
        let settings = try ServiceCodec.decode(NotificationSettings.self, from: ServiceCodec.encode(input))
        try Self.validate(settings)
        let previous = try effectiveSettings()
        guard settings.records.count >= previous.records.count,
              previous.records.allSatisfy({ settings.record(for: $0.scope) != nil })
        else { throw ServiceFailure.invalidRequest }
        for record in settings.records where previous.record(for: record.scope)?.value != record.value {
            let old = previous.record(for: record.scope)
            let existing = pending.firstIndex { $0.scope == record.scope }
            var edit = PolicyEdit(
                scope: record.scope,
                change: .value(record.value),
                modifiedAt: record.modifiedAt,
                modifiedBy: record.modifiedBy
            )
            switch record.value {
            case .rule:
                let before = try PolicyEdit.fields(old?.value)
                let after = try PolicyEdit.fields(record.value)
                var fields: [String: PolicyFieldEdit] = [:]
                if let existing, case let .rule(prior) = pending[existing].change {
                    fields = Dictionary(uniqueKeysWithValues: prior.map { ($0.key, $0) })
                }
                for key in Set(before.keys).union(after.keys) where before[key] != after[key] {
                    fields[key] = PolicyFieldEdit(
                        key: key,
                        removes: after[key] == nil,
                        value: after[key] ?? .null
                    )
                }
                let base = try PolicyEdit.fields(acknowledged?.settings.record(for: record.scope)?.value)
                fields = fields.filter { key, field in base[key] != (field.removes ? nil : field.value) }
                edit.change = .rule(fields.values.sorted { $0.key < $1.key })
            case .keywords, .pause:
                if let old, case .unknown = old.value {
                    throw ServiceFailure.policyUnavailable
                }
            case .unknown: throw ServiceFailure.policyUnavailable
            }
            if let existing {
                pending[existing] = edit
            } else {
                pending.append(edit)
            }
        }
        if let acknowledged {
            pending = try pending.filter { try !$0.isFulfilled(by: acknowledged.settings) }
        }
        try validate(for: binding)
    }
}
