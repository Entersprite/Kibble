import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The demo world exists to be looked at, which means its failure mode is a
/// blank name or a missing message in a screenshot rather than a red test.
/// These are the tests that make it a red test instead.
@Suite(.timeLimit(.minutes(1)))
struct DemoWorldTests {
    @Test func theDemoWorldIsSelfConsistent() {
        #expect(FixtureWorld.acme.inconsistencies().isEmpty)
    }

    /// Maya has a custom status and a meeting, so the Debug app shows both
    /// marks on one row. Fixed dates, no clock: the meeting covers any day the
    /// app is likely to be run on.
    @Test func mayaIsInAMeetingBesideHerStatus() throws {
        let maya = try #require(FixtureWorld.acme.members.first { $0.id == Acme.maya })
        #expect(maya.status?.emoji == "🎧")
        let someDay = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(maya.calendar?.current(at: someDay)?.kind == .inMeeting)
        #expect(maya.calendar?.current(at: someDay)?.until == nil)
    }

    @Test func theDemoWorldHasOneOfEachKindWorthRendering() {
        let kinds = Set(FixtureWorld.acme.conversations.map(\.kind))
        #expect(kinds.contains(.directMessage))
        #expect(kinds.contains(.groupDirectMessage))
        #expect(kinds.contains(.space))
    }

    /// Deliberate. Whether Meet-call chats are their own category is unresolved
    /// against the real protocol, and the resolution recorded in the
    /// architecture design was to model `kind` as an open enum. Shipping one
    /// unknown kind in the demo world means the UI meets that branch on its
    /// first day instead of in production.
    @Test func theDemoWorldCarriesAnUnknownConversationKindOnPurpose() {
        #expect(FixtureWorld.acme.conversations.contains { $0.kind == .unknown("meetCall") })
    }

    @Test func theDemoWorldHasAThreadWithMoreThanOneMessageInIt() {
        let world = FixtureWorld.acme
        let threaded = world.conversations.filter(\.isThreaded)
        #expect(!threaded.isEmpty)
        let counts = Dictionary(grouping: world.messages, by: \.threadID).mapValues(\.count)
        #expect(counts.values.contains { $0 > 1 })
    }

    @Test func everyDemoConversationHasSomethingToShow() {
        let world = FixtureWorld.acme
        for conversation in world.conversations {
            #expect(!world.messages(in: conversation.id).isEmpty, "\(conversation.id) is empty")
        }
    }

    /// The demo world exists partly to exercise a sidebar that scrolls: the
    /// footer used to draw over the rows behind it, and a seven-row world was
    /// short enough to hide that entirely. This is a floor, not an assertion
    /// about the exact filler - deleting `+AcmeFiller` to tidy up would
    /// quietly take the regression case with it.
    @Test func theDemoWorldIsLongEnoughToScroll() {
        #expect(FixtureWorld.acme.conversations.count >= 25)
    }

    /// A demo script naming a conversation or a person the world does not have
    /// would throw halfway through a demo. Playing it start to finish here is
    /// the cheapest possible proof that it will not.
    @Test func theDemoScriptOnlyNamesThingsTheDemoWorldHas() async throws {
        let backend = FakeBackend(world: .acme)
        try await backend.connect()
        try await backend.play(.acmeDemo)
    }

    @Test func theDemoScriptSaysSomethingWorthWatching() {
        #expect(FixtureScript.acmeDemo.steps.count > 4)
        #expect(FixtureScript.acmeDemo.steps.contains {
            if case .delay = $0 {
                true
            } else {
                false
            }
        })
    }

    /// The Mentions row has something to show under `--backend=fixture`: one
    /// line naming the local user and one `@all`, both from someone else,
    /// both with a span that lands on "@" in UTF-16 (`findings.md` §41.1).
    @Test func theDemoWorldMentionsTheLocalUserByNameAndThroughAll() {
        let world = FixtureWorld.acme
        let mentioning = world.messages.filter { $0.mentionsMe(world.me) }
        #expect(mentioning.count == 2)
        let targets = mentioning.flatMap(\.mentions).map(\.target)
        #expect(targets.contains(.user(world.me)))
        #expect(targets.contains(.all))
        for message in mentioning {
            let units = Array(message.text.utf16)
            for mention in message.mentions {
                #expect(mention.start + mention.length <= units.count)
                #expect(units[mention.start] == UInt16(UInt8(ascii: "@")))
            }
        }
    }
}

/// The driver is the only thing in the package that waits, so these are the
/// only tests that can be slow - and they are written so that they are not.
@Suite(.timeLimit(.minutes(1)))
struct DemoDriverTests {
    private let dm = Conversation.ID("dm:1")
    private let other = Member.ID("fixture-other")

    @Test func theDriverPlaysItsScriptIntoTheBackend() async throws {
        let backend = FakeBackend(world: .minimal)
        let collector = EventCollector(backend.events)
        let driver = FixtureDemoDriver(
            backend: backend,
            script: FixtureScript(steps: [
                .typing(conversation: dm, member: other, isTyping: true),
                .typing(conversation: dm, member: other, isTyping: false)
            ]),
            repeats: false
        )

        await driver.start()

        let events = await collector.next(2)
        try #require(events.count == 2)
        #expect(events[0] == .typingChanged(conversationID: dm, member: other, isTyping: true))
        #expect(events[1] == .typingChanged(conversationID: dm, member: other, isTyping: false))
    }

    /// The delay is ten minutes so that the test can only pass by cancelling,
    /// never by outracing it.
    @Test func stoppingCutsTheScriptShort() async throws {
        let backend = FakeBackend(world: .minimal)
        let collector = EventCollector(backend.events)
        let driver = FixtureDemoDriver(
            backend: backend,
            script: FixtureScript(steps: [
                .gap(scope: .everything, reason: "first"),
                .delay(.seconds(600)),
                .gap(scope: .everything, reason: "never reached")
            ]),
            repeats: false
        )

        await driver.start()
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "first"))
        await driver.stop()

        try await backend.apply(.gap(scope: .everything, reason: "sentinel"))
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "sentinel"))
    }

    @Test func stoppingBeforeStartingIsHarmless() async {
        let driver = FixtureDemoDriver(backend: FakeBackend(world: .minimal), repeats: false)
        await driver.stop()
    }

    @Test func startingTwiceDoesNotRunTheScriptTwice() async throws {
        let backend = FakeBackend(world: .minimal)
        let collector = EventCollector(backend.events)
        let driver = FixtureDemoDriver(
            backend: backend,
            script: FixtureScript(steps: [
                .gap(scope: .everything, reason: "once"),
                .delay(.seconds(600))
            ]),
            repeats: false
        )

        await driver.start()
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "once"))
        await driver.start()
        await driver.stop()

        try await backend.apply(.gap(scope: .everything, reason: "sentinel"))
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "sentinel"))
    }
}
