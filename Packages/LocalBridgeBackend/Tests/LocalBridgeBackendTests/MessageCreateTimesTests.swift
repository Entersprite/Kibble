import ChatKit
import Foundation
import Testing
@testable import LocalBridgeBackend

/// The bridge's memory of each mapped message's create time, in
/// microseconds: what an anchored history page is built from
/// (`findings.md` §65.9).
struct MessageCreateTimesTests {
    private func message(_ id: String, micros: Int64) -> ChatKit.Message {
        ChatKit.Message(
            id: ChatKit.Message.ID(id), conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID(id), sender: Member.ID("u-1"), text: "x",
            createdAt: Microseconds.date(micros)
        )
    }

    /// A mapped `createdAt` came from the wire's microseconds in memory, so
    /// reading the microseconds back from it is exact - pinned on 16-digit
    /// values like the wire's, none a whole millisecond, so any path through
    /// milliseconds (or a store that keeps them) fails every case (CLAUDE.md:
    /// "a measurement cannot be finer than the store it was read from").
    @Test(arguments: [
        Int64(1_790_123_456_789_012), 1_700_000_000_000_001, 1_799_999_999_999_999, 1_760_000_000_123_457
    ])
    func aSixteenDigitTimeRoundTripsExactly(micros: Int64) {
        var times = MessageCreateTimes()
        times.remember([message("m-1", micros: micros)])
        #expect(times.micros(of: ChatKit.Message.ID("m-1")) == micros)
    }

    @Test func anIDItNeverSawIsUnknown() {
        var times = MessageCreateTimes()
        times.remember([message("m-1", micros: 1_790_000_000_000_000)])
        #expect(times.micros(of: ChatKit.Message.ID("m-2")) == nil)
    }

    @Test func itKeepsTenThousandByDefault() {
        #expect(MessageCreateTimes().capacity == 10000)
    }

    /// Bounded: never more than its capacity, and what goes first is what
    /// was remembered longest ago - never the id just remembered, which is
    /// the search hit about to be opened.
    @Test func itNeverHoldsMoreThanItsCapacity() {
        var times = MessageCreateTimes(capacity: 4)
        for index in 0 ..< 5 {
            times.remember([message("m-\(index)", micros: 1_790_000_000_000_000 + Int64(index))])
            #expect(times.count <= 4)
        }
        #expect(times.micros(of: ChatKit.Message.ID("m-4")) == 1_790_000_000_000_004)
        #expect(times.micros(of: ChatKit.Message.ID("m-0")) == nil)
    }

    /// By when it was remembered, not by its own time: an old hit remembered
    /// last outlives a newer message remembered first.
    @Test func anOldMessageRememberedLastIsKept() {
        var times = MessageCreateTimes(capacity: 4)
        times.remember((0 ..< 4).map { message("new-\($0)", micros: 1_790_000_000_000_000 + Int64($0)) })
        times.remember([message("old-hit", micros: 1_600_000_000_000_000)])
        #expect(times.micros(of: ChatKit.Message.ID("old-hit")) == 1_600_000_000_000_000)
    }

    /// Remembering an id again counts as remembering it now.
    @Test func rememberingAgainRefreshesIt() {
        var times = MessageCreateTimes(capacity: 4)
        times.remember((0 ..< 4).map { message("m-\($0)", micros: 1_790_000_000_000_000 + Int64($0)) })
        times.remember([message("m-0", micros: 1_790_000_000_000_000)])
        times.remember([message("m-4", micros: 1_790_000_000_000_004)])
        #expect(times.micros(of: ChatKit.Message.ID("m-0")) != nil)
        #expect(times.micros(of: ChatKit.Message.ID("m-1")) == nil)
    }

    @Test func forgettingEmptiesIt() {
        var times = MessageCreateTimes()
        times.remember([message("m-1", micros: 1_790_000_000_000_000)])
        times.forgetAll()
        #expect(times.isEmpty)
        #expect(times.micros(of: ChatKit.Message.ID("m-1")) == nil)
    }
}
