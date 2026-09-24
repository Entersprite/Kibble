import ChatKit
import Foundation

public extension Display {
    /// A section's name - the sidebar heading and the settings row alike.
    static func title(of section: SectionKey) -> String {
        switch section {
        case .directMessages: "Direct messages"
        case .groupChats: "Group chats"
        case .spaces: "Spaces"
        case .apps: "Apps"
        case .meetChats: "Meet Chats"
        case .other: "Other"
        case let .unknown(raw): raw
        }
    }

    static func title(of delivery: Delivery) -> String {
        switch delivery {
        case .off: "Off"
        case .notificationCenter: "Notification Center only"
        case .banner: "Banner"
        case .bannerAndSound: "Banner and sound"
        case let .unknown(raw): raw
        }
    }
}
