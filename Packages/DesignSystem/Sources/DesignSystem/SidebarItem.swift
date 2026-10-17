import ChatKit
import Foundation

/// Navigation values never become synthetic backend conversations.
public enum SidebarItem: Hashable, Sendable, Identifiable {
    case conversation(Conversation)
    case meeting(MeetingSeries)

    public var id: SidebarSelection {
        switch self {
        case let .conversation(value): .conversation(value.id)
        case let .meeting(value): .meetingSeries(value.id)
        }
    }

    public var lastActivity: Date? {
        switch self {
        case let .conversation(value): value.lastActivity
        case let .meeting(value): value.lastActivity
        }
    }

    public func title(directory: [Member.ID: Member], me: Member.ID?) -> String {
        switch self {
        case let .conversation(value): Display.title(of: value, directory: directory, me: me)
        case let .meeting(value): value.title
        }
    }

    var stableOrder: String {
        switch self {
        case let .conversation(value): "conversation/" + value.id.rawValue
        case let .meeting(value): "meeting/" + value.id.rawValue
        }
    }
}
