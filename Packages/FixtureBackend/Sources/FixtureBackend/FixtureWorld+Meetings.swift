import ChatKit
import Foundation

public extension FixtureWorld {
    /// A recreated recurring meeting, a different title, and a same-title one-off chat.
    /// The first occurrence has a later message than the latest occurrence.
    static let recurringMeetings: FixtureWorld = {
        var world = FixtureWorld.minimal
        let start = world.startedAt
        let specs = [
            ("planning-first", "planning-previous", 0),
            ("planning-latest", "planning", 86400),
            ("other-planning", "other", 43200)
        ]
        world.conversations = specs.map { id, series, offset in
            let title = series == "other" ? "Other Planning" : "Planning"
            return Conversation(
                id: .init(id), kind: .meetChat, title: "\(title) - occurrence",
                lastActivity: start.addingTimeInterval(Double(offset + 120)), hasUnread: true,
                members: world.members.map(\.id),
                meeting: MeetingOccurrence(
                    seriesID: .init(series), occurrenceID: id,
                    seriesTitle: title,
                    scheduledStart: start.addingTimeInterval(Double(offset))
                )
            )
        } + [Conversation(id: .init("one-off"), kind: .meetChat, title: "Planning")]
        world.messages = specs.flatMap { id, _, offset in
            (0 ..< 3).map { number in
                Message(
                    id: .init("\(id)-\(number)"), conversationID: .init(id),
                    threadID: .init("\(id)-topic-\(number)"), sender: world.members[number % 2].id,
                    text: [
                        "Sharing the agenda.",
                        "Let’s start with the launch date.",
                        "I’ll send the updated plan."
                    ][number],
                    createdAt: start.addingTimeInterval(Double(offset + number * 60))
                )
            }
        }
        world.messages.append(Message(
            id: .init("late-old-message"), conversationID: .init("planning-first"),
            threadID: .init("late-old-topic"), sender: world.me, text: "Notes from our previous meeting.",
            createdAt: start.addingTimeInterval(90000)
        ))
        world.conversations[0].lastActivity = start.addingTimeInterval(90000)
        world.messages.sort { $0.createdAt < $1.createdAt }
        return world
    }()
}
