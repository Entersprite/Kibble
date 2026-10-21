import ChatKit
import CoreGraphics
import Foundation
import Testing
@testable import DesignSystem

/// The floating Jump to Latest, the rotors, following a growing last row and
/// the text bubble's widest, as pure rules.
@MainActor
struct TranscriptControlsTests {
    @Test func jumpToLatestShowsOnlyWhereItCanGoSomewhere() {
        typealias Jump = TranscriptLatestJump
        func action(
            nearBottom: Bool = false, hasNewer: Bool = false, latestJump: Bool = false,
            canLoadNewer: Bool = true, loading: Bool = false, isEmpty: Bool = false
        ) -> Jump.Action? {
            Jump.action(nearBottom: nearBottom, Jump.Context(
                hasNewer: hasNewer, latestJump: latestJump, canLoadNewer: canLoadNewer, loading: loading,
                isEmpty: isEmpty
            ))
        }
        #expect(action(nearBottom: true) == nil)
        #expect(action() == .scroll)
        #expect(action(nearBottom: true, hasNewer: true, latestJump: true) == .load)
        #expect(action(hasNewer: true, latestJump: true, canLoadNewer: false) == nil)
        // A window trimmed below by paging has no latest jump to offer.
        #expect(action(hasNewer: true, latestJump: false) == nil)
        #expect(action(loading: true) == nil)
        #expect(action(isEmpty: true) == nil)
    }

    @Test func followingNeedsGrowthSeenFromTheBottom() {
        typealias End = TranscriptEndTracking.End
        let follows = TranscriptEndTracking.followsGrowth
        #expect(follows(End(height: 40, nearBottom: true), End(height: 180, nearBottom: false)))
        #expect(follows(End(height: 40, nearBottom: true), End(height: 60, nearBottom: true)))
        #expect(!follows(End(height: 40, nearBottom: false), End(height: 180, nearBottom: false)))
        #expect(!follows(End(height: 40, nearBottom: true), End(height: 40.4, nearBottom: true)))
        #expect(!follows(End(height: 60, nearBottom: true), End(height: 40, nearBottom: true)))
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
