import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// What a conversation and a person are called on screen.
struct DisplayTests {
    private let me = Member.ID("me")
    private let alice = Member.ID("alice")
    private let bob = Member.ID("bob")

    private var directory: [Member.ID: Member] {
        [
            me: Member(id: me, kind: .human, displayName: "Me"),
            alice: Member(id: alice, kind: .human, displayName: "Alice Adams"),
            bob: Member(id: bob, kind: .human, displayName: "Bob Brown"),
            Member.ID("app"): Member(id: Member.ID("app"), kind: .app)
        ]
    }

    @Test func aServerTitleIsUsedAsGiven() {
        let space = Conversation(id: Conversation.ID("space:1"), kind: .space, title: "price-engine")
        #expect(Display.title(of: space, directory: directory, me: me) == "price-engine")
    }

    /// A DM has no server-provided title, so one is derived from the people in
    /// it - excluding yourself, because a DM named after you is useless.
    @Test func aDirectMessageIsNamedAfterTheOtherPerson() {
        let dm = Conversation(
            id: Conversation.ID("dm:1"),
            kind: .directMessage,
            members: [me, alice]
        )
        #expect(Display.title(of: dm, directory: directory, me: me) == "Alice Adams")
    }

    @Test func aGroupIsNamedAfterEveryoneElse() {
        let group = Conversation(
            id: Conversation.ID("dm:2"),
            kind: .groupDirectMessage,
            members: [me, alice, bob]
        )
        #expect(Display.title(of: group, directory: directory, me: me) == "Alice Adams, Bob Brown")
    }

    /// An empty title is a title the server really sent, and is not the same as
    /// having none. Deriving over it would be overriding the server.
    @Test func anEmptyServerTitleIsRespectedRatherThanDerivedOver() {
        let space = Conversation(id: Conversation.ID("space:1"), kind: .space, title: "")
        #expect(Display.title(of: space, directory: directory, me: me) == "")
    }

    @Test func aConversationWithNobodyElseInItFallsBackToItsIdentifier() {
        let empty = Conversation(id: Conversation.ID("dm:9"), kind: .directMessage, members: [me])
        #expect(Display.title(of: empty, directory: directory, me: me) == "dm:9")
    }

    /// An app has no display name anywhere - the API returns only a name and a
    /// type, and there is no profile to look up - so the UI must not render a
    /// blank.
    @Test func anAppWithNoNameFallsBackToItsIdentifier() {
        #expect(Display.name(of: Member.ID("app"), in: directory) == "app")
    }

    @Test func someoneTheDirectoryHasNeverHeardOfStillRenders() {
        #expect(Display.name(of: Member.ID("ghost"), in: directory) == "ghost")
    }

    @Test func initialsComeFromTheDisplayName() {
        #expect(Display.initials(of: alice, in: directory) == "AA")
        #expect(Display.initials(of: Member.ID("app"), in: directory) == "AP")
    }

    // MARK: - The sidebar footer's identity row

    @Test func aResolvedMeShowsItsDisplayName() {
        #expect(Display.signedInLabel(me: me, directory: directory) == "Me")
    }

    /// A resolved id the directory has not caught up with yet still shows
    /// something, the same fallback `name(of:in:)` already gives anyone else -
    /// a signed-in person is not a special case.
    @Test func aResolvedMeWithNoDirectoryEntryFallsBackToItsIdentifier() {
        #expect(Display.signedInLabel(me: Member.ID("ghost"), directory: directory) == "ghost")
    }

    /// `me == nil` - the one gap `AppEnvironment` documents as real, if brief,
    /// on the live backend - draws a plain placeholder rather than an empty
    /// or half-built row.
    @Test func anUnresolvedMeShowsAPlaceholderRatherThanBeingBlank() {
        #expect(Display.signedInLabel(me: nil, directory: directory) == "Signed in")
    }

    // MARK: - hasName

    /// `Avatar` picks between initials and a plain person glyph on this, so a
    /// wrong answer is two arbitrary characters cut out of an opaque
    /// identifier - which is exactly what Messages shows a person glyph
    /// instead of.
    @Test func hasNameIsTrueOnlyWhenSomebodyActuallyToldUsOne() {
        #expect(Display.hasName(of: alice, in: directory))
        // In the directory, but an app has no profile under user auth.
        #expect(!Display.hasName(of: Member.ID("app"), in: directory))
        // Not in the directory at all.
        #expect(!Display.hasName(of: Member.ID("stranger"), in: directory))
    }

    /// The same trimming rule `name(of:in:)` applies. A name of spaces is not a
    /// name, and the two must never disagree about that.
    @Test func aWhitespaceOnlyNameDoesNotCountAsAName() {
        let blank = Member.ID("blank")
        let directory = [blank: Member(id: blank, kind: .human, displayName: "   ")]
        #expect(!Display.hasName(of: blank, in: directory))
        #expect(Display.name(of: blank, in: directory) == "blank")
    }

    /// The invariant that makes the pair safe: `hasName` is false in exactly
    /// the cases where `name(of:in:)` gives back the raw identifier.
    @Test func hasNameAgreesWithWhenNameFallsBackToTheIdentifier() {
        let cases = [alice, bob, me, Member.ID("app"), Member.ID("stranger")]
        for member in cases {
            let fellBack = Display.name(of: member, in: directory) == member.rawValue
            #expect(Display.hasName(of: member, in: directory) == !fellBack, "\(member)")
        }
    }

    // MARK: - Timestamps

    /// UTC and `en_US`, so the assertions below are about which **branch** was
    /// taken and never about how a locale spells a month.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let english = Locale(identifier: "en_US")

    private func at(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func stamp(_ date: String, now: String) -> String {
        Display.timestamp(of: at(date), now: at(now), calendar: utc, locale: english)
    }

    /// Today carries no date at all - the whole point of the branch.
    @Test func todayShowsTimeOnly() {
        let rendered = stamp("2026-09-09T15:25:00Z", now: "2026-09-09T18:00:00Z")
        #expect(!rendered.contains("Yesterday"))
        #expect(!rendered.contains("Sep"))
        #expect(!rendered.contains("2026"))
    }

    /// Ten minutes elapsed, but across midnight - so "Yesterday", not today.
    /// Start-of-day comparison is what makes this right, and an elapsed-hours
    /// comparison is what would get it wrong.
    @Test func tenMinutesAcrossMidnightIsYesterdayNotToday() {
        #expect(stamp("2026-09-08T23:50:00Z", now: "2026-09-09T00:10:00Z").hasPrefix("Yesterday"))
    }

    /// Twenty-three hours elapsed, same calendar day - so today, despite being
    /// nearly a day. The mirror of the case above, and the reason the two
    /// cannot both be satisfied by a duration threshold.
    @Test func twentyThreeHoursWithinOneDayIsStillToday() {
        let rendered = stamp("2026-09-09T00:10:00Z", now: "2026-09-09T23:10:00Z")
        #expect(!rendered.contains("Yesterday"))
        #expect(!rendered.contains("Sep"))
    }

    /// Yesterday across a month end. `1` has to come from real calendar
    /// arithmetic rather than a day-of-month subtraction, which would give -30.
    @Test func yesterdayAcrossAMonthEndIsStillYesterday() {
        #expect(stamp("2026-08-31T22:00:00Z", now: "2026-09-01T09:00:00Z").hasPrefix("Yesterday"))
    }

    /// Two days is dated, and within the same year carries no year.
    @Test func earlierThisYearShowsMonthAndDayWithoutTheYear() {
        let rendered = stamp("2026-09-04T15:25:00Z", now: "2026-09-09T09:00:00Z")
        #expect(rendered.contains("Sep"))
        #expect(!rendered.contains("2026"))
        #expect(!rendered.contains("Yesterday"))
    }

    /// A previous year carries the year, because "Sep 4" alone is ambiguous
    /// once history loads far enough back - and it does.
    @Test func anEarlierYearShowsTheYear() {
        let rendered = stamp("2025-09-04T15:25:00Z", now: "2026-09-09T09:00:00Z")
        #expect(rendered.contains("2025"))
        #expect(rendered.contains("Sep"))
    }

    /// Yesterday across a **year** end is still yesterday, and must not fall
    /// into the year-bearing branch: the day arithmetic is checked before the
    /// year comparison, and reversing the two would print
    /// "Dec 31, 2025" for a message from last night.
    @Test func yesterdayAcrossAYearEndIsYesterdayNotADatedYear() {
        let rendered = stamp("2025-12-31T23:30:00Z", now: "2026-01-01T00:30:00Z")
        #expect(rendered.hasPrefix("Yesterday"))
        #expect(!rendered.contains("2025"))
    }

    /// A timestamp ahead of `now` - clock skew, or a peer ahead of us - is
    /// dated rather than crashing or claiming to be today. Not a case worth a
    /// special label; this pins that it stays in a defined branch.
    @Test func aFutureTimestampIsDatedRatherThanToday() {
        let rendered = stamp("2026-09-11T10:00:00Z", now: "2026-09-09T09:00:00Z")
        #expect(rendered.contains("Sep"))
        #expect(!rendered.contains("Yesterday"))
    }
}
