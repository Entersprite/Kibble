import ChatKit
import Foundation
import GChatBridgeCore

struct GroupNotificationMapping {
    let level: NotificationLevel?
    let isMuted: Bool?
    let muteUntil: Date?

    init(_ readState: GroupReadState, now: Date = .now) {
        self.init(readState.notificationSettings, now: now)
    }

    init(_ settings: GroupNotificationSettings, now: Date = .now) {
        level = Self.level(in: settings)
        let mute = settings.muteSettings
        let expiry = Self.expiry(in: mute)
        switch mute.state {
        case .unmuted: isMuted = false
        case .muted: isMuted = expiry.map { now < $0 } ?? true
        case .muteStateUnspecified: isMuted = nil
        }
        muteUntil = isMuted == true ? expiry : nil
    }

    private static func level(in settings: GroupNotificationSettings) -> NotificationLevel? {
        if let raw = ProtoFieldScan.varintValues(ofField: 2, in: settings.unknownFields.data).last {
            return .unknown("provider:\(raw)")
        }
        guard settings.hasRoomState else { return nil }
        switch settings.roomState {
        case .notifyAll: return .always
        case .notifyMainConversation: return .lessWithNewThreads
        case .notifyLess: return .less
        case .notifyNever: return .never
        case .notifyAlways, .notifyLessWithNewThreads:
            return .unknown("provider:\(settings.roomState.rawValue)")
        }
    }

    static func expiry(in mute: GroupNotificationSettings.MuteSettings) -> Date? {
        guard mute.hasExpiry, (0 ..< 1_000_000_000).contains(mute.expiry.nanos) else { return nil }
        let seconds = Double(mute.expiry.seconds) + Double(mute.expiry.nanos) / 1_000_000_000
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }
}
