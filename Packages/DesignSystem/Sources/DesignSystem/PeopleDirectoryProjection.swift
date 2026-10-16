import ChatKit
import Foundation

/// One people list combines known contacts and directory matches without duplicate rows.
enum PeopleDirectoryProjection {
    static func build(_ state: ChatSceneState) -> [Member] {
        let found = state.browser.people
        let query = state.browser.query
        let me = state.me
        let preference = state.sidebarPreferences.orderedSections.first { $0.id == "directMessage" }
            ?? .init(id: "directMessage")
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
                return preference.sortsAscending ? comparison == .orderedAscending :
                    comparison == .orderedDescending
            }
            return left.id.rawValue < right.id.rawValue
        }
    }
}
