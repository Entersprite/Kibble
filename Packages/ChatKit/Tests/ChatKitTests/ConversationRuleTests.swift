import Foundation
import Testing
@testable import ChatKit

struct ConversationRuleTests {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private let dm = Conversation(id: Conversation.ID("dm/1"), kind: .directMessage)
    private let meet = Conversation(id: Conversation.ID("space/m"), kind: .meetChat)

    /// Review Focus 1: Unmute clears exactly the three fields Mute writes,
    /// even one set by hand before muting, and nothing else.
    @Test func unmuteClearsExactlyWhatMuteWritesAndKeepsTheRest() {
        let before = NotificationRule(showsUnread: true, readReceipts: false)
        let muted = before.muted()
        #expect(muted == NotificationRule(
            delivery: .off, showsUnread: false, countsInBadge: false, readReceipts: false
        ))
        #expect(muted.unmuted() == NotificationRule(readReceipts: false))
    }

    /// Muted means the conversation's own record says Off. Inherited Off -
    /// a silent section, the Meet preset - is not muted, so Unmute is never
    /// offered where it could change nothing.
    @Test func onlyAConversationsOwnOffIsMuted() {
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(delivery: .off), for: .section(.directMessages), at: at, by: "t")
        #expect(!settings.isMuted(dm.id))
        #expect(!settings.isMuted(meet.id))
        settings.setRule(NotificationRule().muted(), for: .conversation(dm.id), at: at, by: "t")
        #expect(settings.isMuted(dm.id))
    }

    /// Review Focus 2: a muted Meet chat is muted, and unmuting returns it to
    /// the preset - still Off, still not counted - not to the global default.
    @Test func unmutingAMeetChatReturnsItToThePreset() {
        var settings = NotificationSettings()
        settings.setRule(NotificationRule().muted(), for: .conversation(meet.id), at: at, by: "t")
        #expect(settings.isMuted(meet.id))
        settings.setRule(NotificationRule().muted().unmuted(), for: .conversation(meet.id), at: at, by: "t")
        #expect(!settings.isMuted(meet.id))
        #expect(settings.resolve(for: meet).delivery == .off)
        #expect(!settings.resolve(for: meet).countsInBadge)
    }

    /// The editor's "Default (…)" values: the chain without the
    /// conversation's own record.
    @Test func whatAConversationInheritsExcludesItsOwnRecord() {
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(delivery: .banner), for: .section(.directMessages), at: at, by: "t")
        settings.setRule(NotificationRule(delivery: .off), for: .conversation(dm.id), at: at, by: "t")
        #expect(settings.inherited(byConversation: dm).delivery == .banner)
        #expect(settings.resolve(for: dm).delivery == .off)
    }

    /// The Conversations pane lists records with something in them; an
    /// emptied record (Reset, Unmute of a plain mute) is not an override.
    @Test func customizedConversationsSkipEmptiedRecordsAndOtherScopes() {
        var settings = NotificationSettings()
        let other = Conversation.ID("space/s")
        settings.setRule(NotificationRule(delivery: .off), for: .global, at: at, by: "t")
        settings.setRule(NotificationRule(showsPreview: false), for: .conversation(dm.id), at: at, by: "t")
        settings.setRule(NotificationRule(), for: .conversation(other), at: at, by: "t")
        #expect(settings.customizedConversations == [dm.id])
    }
}
