import AppKit
import ChatKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// The floating jump to the newest, unseen arrivals, tapbacks, the rotors
/// and the text bubble's widest.
@MainActor
struct TranscriptControlsTests {
    @Test func jumpToLatestShowsOnlyWhereItCanGoSomewhere() {
        typealias Jump = TranscriptLatestJump
        func action(
            following: Bool = false, hasNewer: Bool = false, latestJump: Bool = false,
            canLoadNewer: Bool = true, loading: Bool = false, isEmpty: Bool = false
        ) -> Jump.Action? {
            Jump.action(following: following, Jump.Context(
                hasNewer: hasNewer, latestJump: latestJump, canLoadNewer: canLoadNewer, loading: loading,
                isEmpty: isEmpty
            ))
        }
        #expect(action(following: true) == nil)
        #expect(action() == .scroll)
        #expect(action(following: true, hasNewer: true, latestJump: true) == .load)
        #expect(action(hasNewer: true, latestJump: true, canLoadNewer: false) == nil)
        // A window trimmed below by paging has no latest jump to offer.
        #expect(action(hasNewer: true, latestJump: false) == nil)
        #expect(action(loading: true) == nil)
        #expect(action(isEmpty: true) == nil)
    }

    @Test func theJumpSaysNewMessagesOnlyWhenSomethingArrived() {
        #expect(JumpToLatestButton.title(unseen: false) == "Jump to Newest")
        #expect(JumpToLatestButton.title(unseen: true) == "New Messages")
    }

    /// Only someone else's message arriving while the newest end is out of
    /// view turns the jump into New Messages; history, a trimmed window and
    /// your own message do not.
    @Test func onlyAnUnseenArrivalFromSomeoneElseCounts() {
        let alex = Member.ID("alex")
        let me = Member.ID("me")
        func message(_ id: String, _ sender: Member.ID = alex) -> Message {
            Message(
                id: Message.ID(id), conversationID: Conversation.ID("c"), threadID: MessageThread.ID("t"),
                sender: sender, text: id, createdAt: Date(timeIntervalSince1970: 0)
            )
        }
        func unseen(_ old: String?, _ new: String?, _ messages: [Message], expected: Bool = false) -> Bool {
            let before: Message.ID? = old.map { Message.ID($0) }
            let after: Message.ID? = new.map { Message.ID($0) }
            return TranscriptArrival.isUnseen(
                from: before, to: after, messages: messages, me: me, expected: expected
            )
        }
        let arrived = [message("a"), message("b")]
        #expect(unseen("a", "b", arrived))
        // Following the newest end, or a page of history asked for.
        #expect(!unseen("a", "b", arrived, expected: true))
        #expect(!unseen("a", "b", [message("a"), message("b", me)]))
        // The window trimmed below: the old newest is gone, nothing arrived.
        #expect(!unseen("z", "b", arrived))
        #expect(!unseen(nil, "b", arrived))
        #expect(!unseen("b", "b", arrived))
    }

    /// A tapback shows a count only when more than one chose the emoji, and
    /// at most five emoji before the rest are counted.
    @Test func aTapbackStaysSmall() {
        let one = Reaction(emoji: "👍", count: 1, includesMe: true)
        let two = Reaction(emoji: "🎉", count: 2)
        let single = NSHostingView(rootView: ReactionCapsuleContent(reaction: one, showsSingleCount: false))
        let counted = NSHostingView(rootView: ReactionCapsuleContent(reaction: one))
        #expect(single.fittingSize.width < counted.fittingSize.width)
        #expect(NSHostingView(rootView: ReactionCapsuleContent(reaction: two, showsSingleCount: false))
            .fittingSize.width > single.fittingSize.width)

        let emoji = ["😀", "😃", "😄", "😁", "😆", "😅", "🤣"]
        let many = emoji.map { Reaction(emoji: $0, count: 1) }
        let five = NSHostingView(rootView: ReactionTapbacks(reactions: Array(many.prefix(5)), isMine: false))
        let seven = NSHostingView(rootView: ReactionTapbacks(reactions: many, isMine: false))
        // Seven draws five and "+2", not seven.
        #expect(seven.fittingSize.width > five.fittingSize.width)
        #expect(seven.fittingSize.width < five.fittingSize.width + 40)
        #expect(five.fittingSize.height == ReactionTapbacks.height)
    }

    @Test func theWidestBubbleIsThreeQuartersOfTheColumnUpTo560() {
        #expect(MessageBubbleLayout.maxTextWidth(row: 480) == 360)
        #expect(MessageBubbleLayout.maxTextWidth(row: 700) == 525)
        #expect(MessageBubbleLayout.maxTextWidth(row: 1000) == 560)
        #expect(MessageBubbleLayout.maxTextWidth(row: 0) == 560)
        #expect(MessageBubbleLayout.maxTextWidth(row: .infinity) == 560)
        // Measured: an `HStack` row offers the column its width less these.
        #expect(MessageBubbleLayout.reserve(isMine: false) == 102)
        #expect(MessageBubbleLayout.reserve(isMine: true) == 68)
    }

    @Test func theRotorsFindMentionsOfMeAndLinks() throws {
        let me = Member.ID("me")
        let alex = Member.ID("alex")
        let space = Conversation.ID("space/s-1")
        func message(
            _ id: String,
            _ text: String,
            mentions: [Mention] = [],
            links: [MessageLink] = []
        ) -> Message {
            Message(
                id: Message.ID(id), conversationID: space, threadID: MessageThread.ID(id), sender: alex,
                text: text, createdAt: Date(timeIntervalSince1970: 0), mentions: mentions, links: links
            )
        }
        let site = try #require(URL(string: "https://example.com"))
        let sam = Mention(target: .user(Member.ID("sam")), start: 0, length: 4)
        let messages = [
            message("1", "@You look", mentions: [Mention(target: .user(me), start: 0, length: 4)]),
            message("2", "@Sam look", mentions: [sam]),
            message("3", "see https://example.com", links: [MessageLink(url: site)]),
            message("4", "plain")
        ]
        #expect(TranscriptRotors.mentioningMe(messages, me: me).map(\.id.rawValue) == ["1"])
        #expect(TranscriptRotors.withLinks(messages).map(\.id.rawValue) == ["3"])
        let directory = [alex: Member(id: alex, kind: .human, displayName: "Alex Lee")]
        #expect(TranscriptRotors.label(for: messages[3], directory: directory) == "Alex Lee: plain")
        let long = message("5", String(repeating: "word ", count: 40))
        #expect(TranscriptRotors.label(for: long, directory: directory).hasSuffix("…"))
    }
}
