import ChatKit
import Foundation

/// One people list combines known contacts and directory matches without duplicate rows.
enum PeopleDirectoryProjection {
    static func build(_ state: ChatSceneState) -> [Member] {
        people(
            in: state,
            query: state.browser.query,
            found: state.browser.people,
            preference: state.sidebarPreferences.section("directMessage")
        )
    }

    /// The people a picker offers: everyone the search found plus every known
    /// person whose name or address matches, so local matches show while the
    /// directory is still answering. Most recent conversation partners first,
    /// then by name. With no query, the `suggestionLimit` most recent only.
    static func candidates(
        in state: ChatSceneState,
        query: String,
        found: [Member],
        excluding: Set<Member.ID>,
        suggestionLimit: Int = 12,
        limit: Int = 50
    ) -> [Member] {
        let matches = people(
            in: state,
            query: query,
            found: query.isEmpty ? [] : found,
            preference: SidebarSectionPreference(id: "directMessage")
        ).filter { !excluding.contains($0.id) }
        return Array(matches.prefix(query.isEmpty ? suggestionLimit : limit))
    }

    static func people(
        in state: ChatSceneState,
        query: String,
        found: [Member],
        preference: SidebarSectionPreference
    ) -> [Member] {
        let me = state.me
        var people = state.directory
        for person in found {
            people[person.id] = person
        }
        let remoteIDs = Set(found.map(\.id))
        var activity: [Member.ID: Date] = [:]
        for conversation in state.conversations where conversation.kind == .directMessage {
            guard let date = conversation.lastActivity else { continue }
            for person in conversation.members where person != me {
                activity[person] = max(activity[person] ?? date, date)
            }
        }
        return people.values.filter { person in
            person.id != me && person.kind == .human && (
                query.isEmpty || remoteIDs.contains(person.id) ||
                    (person.displayName ?? "").localizedCaseInsensitiveContains(query) ||
                    (person.email ?? "").localizedCaseInsensitiveContains(query)
            )
        }.sorted { left, right in
            if preference.sort != .name, activity[left.id] != activity[right.id] {
                switch (activity[left.id], activity[right.id]) {
                case let (left?, right?): return preference.sortsAscending ? left < right : left > right
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            let comparison = Display.name(of: left.id, in: people)
                .localizedStandardCompare(Display.name(of: right.id, in: people))
            if comparison != .orderedSame {
                // Names break an activity tie A to Z; only a name sort reverses them.
                let ascending = preference.sort != .name || preference.sortsAscending
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            return left.id.rawValue < right.id.rawValue
        }
    }
}
