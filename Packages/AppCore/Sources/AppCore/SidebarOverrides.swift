import ChatKit
import Foundation

/// Per-field overrides, so changing an account's sort order does not freeze
/// its inherited visibility or item limit. Favorites always remain account-local.
struct SidebarOverrides: Codable {
    var order: [String]?
    var fields: [String: [String: JSONValue]] = [:]

    mutating func record(before: SidebarPreferences, after: SidebarPreferences) throws {
        let oldOrder = before.orderedSections.map(\.id)
        let newOrder = after.orderedSections.map(\.id)
        if oldOrder != newOrder {
            order = newOrder
        }
        for next in after.displaySections {
            let previous = before.displaySections.first { $0.id == next.id } ?? next
            let old = try Self.object(previous)
            let new = try Self.object(next)
            for key in Set(old.keys).union(new.keys) where key != "id" && old[key] != new[key] {
                fields[next.id, default: [:]][key] = new[key] ?? .null
            }
        }
    }

    func apply(to defaults: SidebarPreferences) throws -> SidebarPreferences {
        var result = defaults
        result.sections = try defaults.displaySections.map { section in
            var object = try Self.object(section)
            for (key, value) in fields[section.id] ?? [:] {
                object[key] = value
            }
            return try JSONDecoder().decode(
                SidebarSectionPreference.self, from: JSONEncoder().encode(object)
            )
        }
        if let order {
            let positions = Dictionary(uniqueKeysWithValues: order.enumerated()
                .map { ($0.element, $0.offset) })
            result.sections.sort { positions[$0.id, default: -1] < positions[$1.id, default: -1] }
        }
        return result
    }

    private static func object(_ value: SidebarSectionPreference) throws -> [String: JSONValue] {
        var value = value
        // Favorites is always unlimited; its Int.max is a presentation sentinel,
        // not a configurable number to round-trip through JSONValue's Double.
        if value.id == "favorites" {
            value.maximumItems = 10
        }
        return try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(value))
    }
}
