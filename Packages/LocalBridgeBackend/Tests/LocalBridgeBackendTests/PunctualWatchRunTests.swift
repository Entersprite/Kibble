import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `--probe=punctual`'s channel: the handshake `findings.md` §47 read out of
/// Chat on the web, driven against a scripted server.
struct PunctualWatchRunTests {
    private static let alice = "111111111111111111111"
    private static let bob = "222222222222222222222"
    private static let me = "333333333333333333333"

    private let people = [
        PunctualWatchRun.Person(id: alice, label: "person 1"),
        PunctualWatchRun.Person(id: bob, label: "person 2"),
        PunctualWatchRun.Person(id: me, label: "self")
    ]

    private let chosen = ScriptedTransport
        .ok(#"["GSESSIONSECRET",1,null,"1234567890123456","6543210987654321"]"#)
    private let opened = ScriptedTransport.ok(#"[[0,["c","SIDSECRET","",8,15,30000]]]"#)
    private let added = ScriptedTransport.ok("[1,0,7]")

    /// Two framed chunks: a push naming Alice with a time, and a keepalive.
    private static func pushChunks() -> [String] {
        let push = #"[[1,[[["user-state-changes"],[[["\#(alice)"],2]]]]]]"#
        let noop = #"[[2,["noop"]]]"#
        return ["\(push.utf8.count)\n\(push)", "\(noop.utf8.count)\n\(noop)"]
    }

    private func run(
        _ transport: any HTTPTransport,
        people: [PunctualWatchRun.Person]? = nil,
        duration: Duration = .seconds(60),
        sleeps: SleepLog = SleepLog()
    ) async -> [String] {
        let log = PunctualProbeLog()
        let credentials = SessionCredentials(
            SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "cookie")])!
        )
        await PunctualWatchRun.run(
            people: people ?? self.people,
            requests: PunctualRequests(endpoints: ChatEndpoints(), key: "KEYSECRET"),
            client: PunctualClient(transport: transport, credentials: credentials),
            settings: PunctualWatchRun.Settings(
                duration: duration,
                firstRID: 5000,
                zx: { "zx" },
                now: { Date(timeIntervalSince1970: 1_790_000_000) },
                reopenGap: .seconds(1),
                maximumEmptyPolls: 3,
                sleep: { await sleeps.record($0) }
            ),
            log: log
        )
        return await log.lines
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func theHandshakeRunsInTheCapturedOrder() async {
        let transport = ScriptedTransport(
            [chosen, opened, added],
            streams: [.init(chunks: Self.pushChunks())]
        )
        _ = await run(transport)
        let sent = await transport.sent
        #expect(sent.map(\.traceLabel) == [
            "punctual-choose-server", "punctual-open", "punctual-add", "punctual-poll", "punctual-poll"
        ])
    }

    /// The first watch opens the channel; the rest go in one request, numbered
    /// on from it, with `ofs` the first of them and the RID one past the open.
    @Test func theRemainingWatchesGoInOneRequestNumberedOnFromTheFirst() async {
        let transport = ScriptedTransport(
            [chosen, opened, added],
            streams: [.init(chunks: Self.pushChunks())]
        )
        _ = await run(transport)
        let sent = await transport.sent
        let open = query(sent[1])
        #expect(open["gsessionid"] == "GSESSIONSECRET")
        #expect(open["RID"] == "5000")
        let add = query(sent[2])
        #expect(add["SID"] == "SIDSECRET")
        #expect(add["RID"] == "5001")
        let body = String(decoding: sent[2].body ?? Data(), as: UTF8.self)
        #expect(body.hasPrefix("count=2&ofs=1&"))
        #expect(body.contains("%5B%5B%5B2%2C"))
        #expect(body.contains("%5B%5B%5B3%2C"))
    }

    /// Each poll acknowledges the highest array it has seen.
    @Test func eachPollAcknowledgesTheHighestArraySeen() async {
        let transport = ScriptedTransport(
            [chosen, opened, added],
            streams: [.init(chunks: Self.pushChunks())]
        )
        _ = await run(transport)
        let polls = await transport.sent.filter { $0.traceLabel == "punctual-poll" }
        #expect(polls.map { query($0)["AID"] } == ["0", "2"])
    }

    @Test func aPushIsPrintedAsItsShapeWithThePersonNamedByLabel() async {
        let transport = ScriptedTransport(
            [chosen, opened, added],
            streams: [.init(chunks: Self.pushChunks())]
        )
        let lines = await run(transport)
        #expect(lines.contains(#"  +00:00 aid=1 [[["user-state-changes"],[[[person 1],2]]]]"#))
        #expect(!lines.contains { $0.contains("noop") })
    }

    @Test func oneWatchedPersonNeedsNoAddRequest() async {
        let transport = ScriptedTransport([chosen, opened], streams: [.init(chunks: [])])
        _ = await run(transport, people: [people[0]])
        #expect(await transport.sent.map(\.traceLabel) == [
            "punctual-choose-server",
            "punctual-open",
            "punctual-poll",
            "punctual-poll"
        ])
    }

    @Test func aRefusedChooseServerStopsTheRun() async {
        let refused: Result<HTTPResponse, any Error> = .success(
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data("denied".utf8))
        )
        let transport = ScriptedTransport([refused])
        let lines = await run(transport)
        #expect(await transport.sent.count == 1)
        #expect(lines.contains("choose server: status 403, 6 bytes"))
        #expect(lines.last == "Stopping: the channel never opened.")
    }

    @Test func aFailedPollIsReportedAndEndsTheRun() async {
        let transport = ScriptedTransport(
            [chosen, opened, added],
            streams: [.init(chunks: Self.pushChunks())]
        )
        let lines = await run(transport)
        #expect(lines.contains { $0.hasPrefix("poll 2 failed: ") })
        #expect(lines.contains("polls: 2, arrays: 2, keepalives: 1"))
    }

    /// A poll still open at the deadline is cancelled, and the run says so
    /// and still writes its summary. The stream here never ends by itself,
    /// the way a real long poll does not.
    @Test(.timeLimit(.minutes(1))) func aPollOpenAtTheDeadlineIsStoppedAndSummarised() async {
        let transport = PollScriptTransport(responses: [chosen, opened, added], polls: [.hangs])
        let lines = await run(transport, duration: .milliseconds(100))
        #expect(lines.contains("poll 1: stopped at the deadline"))
        #expect(lines.contains("polls: 1, arrays: 0, keepalives: 0"))
    }

    // MARK: - Review findings

    /// Finding 1: the channel's own secrets are masked by name wherever they
    /// appear, whatever their case.
    @Test func theChannelsOwnSecretsAreMaskedByName() async {
        let push = #"[[1,["SIDSECRET","KEYSECRET","GSESSIONSECRET"]]]"#
        let transport = ScriptedTransport(
            [chosen, opened, added], streams: [.init(chunks: ["\(push.utf8.count)\n\(push)"])]
        )
        let lines = await run(transport)
        #expect(lines.contains("  +00:00 aid=1 [<sid>,<key>,<gsessionid>]"))
    }

    /// Finding 2: an empty poll is followed by a doubling wait, and a run of
    /// them stops the probe rather than hammering the server.
    @Test func emptyPollsBackOffAndARunOfThemStops() async {
        let transport = PollScriptTransport(
            responses: [chosen, opened, added], polls: [.chunks([]), .chunks([]), .chunks([])]
        )
        let sleeps = SleepLog()
        let lines = await run(transport, sleeps: sleeps)
        #expect(await sleeps.durations == [.seconds(1), .seconds(2)])
        #expect(lines.contains("Stopping: 3 polls in a row carried nothing."))
    }

    /// A poll that carried arrays is followed by the plain gap.
    @Test func aPollThatCarriedArraysWaitsThePlainGap() async {
        let transport = ScriptedTransport(
            [chosen, opened, added],
            streams: [.init(chunks: Self.pushChunks())]
        )
        let sleeps = SleepLog()
        _ = await run(transport, sleeps: sleeps)
        #expect(await sleeps.durations == [.seconds(1)])
    }

    /// Finding 3: a timeout or a lost connection reopens rather than ending
    /// the run, and says why in words.
    @Test func aTimedOutPollReopensAndSaysWhy() async {
        let transport = PollScriptTransport(
            responses: [chosen, opened, added],
            polls: [.fails(ClassifiedTransportFailure(.timedOut)), .chunks(Self.pushChunks())]
        )
        let lines = await run(transport)
        #expect(lines.contains("poll 1: timed out, reopening"))
        #expect(lines.contains { $0.contains("aid=1") })
    }

    /// Finding 7: an error's own text never reaches the report.
    @Test func anErrorsOwnTextNeverReachesTheReport() async {
        let transport = PollScriptTransport(
            responses: [chosen, opened, added],
            polls: [.fails(SentinelError(description: "ERROR-SECRET-TEXT"))]
        )
        let lines = await run(transport)
        #expect(!lines.joined().contains("ERROR-SECRET-TEXT"))
        #expect(lines.contains("poll 1 failed: SentinelError"))
    }

    /// Finding 6: a refused poll ends the run with its status.
    @Test func aRefusedPollEndsTheRunWithItsStatus() async {
        let transport = PollScriptTransport(responses: [chosen, opened, added], polls: [.status(403)])
        let lines = await run(transport)
        #expect(lines.contains("poll 1: status 403"))
    }

    /// Finding 5: the capture never added more than ten at once, so neither
    /// does the probe. Each batch takes the next RID, and `ofs` follows.
    @Test func watchesAreAddedTenAtATime() async throws {
        let many = (1 ... 12).map { PunctualWatchRun.Person(
            id: String(repeating: "\($0 % 10)", count: 21),
            label: "person \($0)"
        ) }
        let transport = ScriptedTransport([chosen, opened, added, added], streams: [.init(chunks: [])])
        _ = await run(transport, people: many)
        let adds = await transport.sent.filter { $0.traceLabel == "punctual-add" }
        #expect(adds.map { query($0)["RID"] } == ["5001", "5002"])
        try #require(adds.count == 2)
        let bodies = adds.map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        #expect(bodies[0].hasPrefix("count=10&ofs=1&"))
        #expect(bodies[1].hasPrefix("count=1&ofs=11&"))
    }

    /// `self` and `person N` collapse only as labels, never inside a word.
    @Test func collapsingTouchesLabelsOnly() {
        #expect(PunctualWatchRun.collapsed(#"["self-status",self,person 3,@now-3m]"#)
            == #"["self-status",person,person,@t]"#)
    }

    /// The report is pasted by hand, so no id, token or key may reach it.
    @Test func theReportNeverCarriesAnIDATokenOrTheKey() async {
        let transport = ScriptedTransport(
            [chosen, opened, added],
            streams: [.init(chunks: Self.pushChunks())]
        )
        let text = await run(transport).joined(separator: "\n")
        for secret in ["GSESSIONSECRET", "SIDSECRET", "KEYSECRET", Self.alice, Self.bob, Self.me, "cookie"] {
            #expect(!text.contains(secret))
        }
    }
}

/// An error whose own text would be a leak if a report printed it.
private struct SentinelError: Error, CustomStringConvertible {
    let description: String
}

/// Records the waits a run asked for instead of waiting.
actor SleepLog {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

/// Answers the handshake from a script, then each poll from its own: framed
/// chunks, a status, a failure to open, or a poll held open until cancelled.
/// Refuses to improvise once a script runs out, like `ScriptedTransport`.
private actor PollScriptTransport: HTTPTransport {
    enum Poll: Sendable {
        case chunks([String])
        case status(Int)
        case fails(any Error & Sendable)
        case hangs
    }

    private var responses: [Result<HTTPResponse, any Error>]
    private var polls: [Poll]

    init(responses: [Result<HTTPResponse, any Error>], polls: [Poll]) {
        self.responses = responses
        self.polls = polls
    }

    func send(_: HTTPRequest) async throws -> HTTPResponse {
        guard !responses.isEmpty else { throw ScriptedTransport.Exhausted() }
        return try responses.removeFirst().get()
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        guard !polls.isEmpty else { throw ScriptedTransport.Exhausted() }
        switch polls.removeFirst() {
        case let .chunks(chunks):
            return HTTPStream(
                status: 200,
                headers: HTTPHeaders([]),
                body: AsyncThrowingStream { continuation in
                    for chunk in chunks {
                        continuation.yield(Data(chunk.utf8))
                    }
                    continuation.finish()
                }
            )
        case let .status(status):
            return HTTPStream(
                status: status,
                headers: HTTPHeaders([]),
                body: AsyncThrowingStream { $0.finish() }
            )
        case let .fails(error):
            throw error
        case .hangs:
            return HTTPStream(status: 200, headers: HTTPHeaders([]), body: AsyncThrowingStream { _ in })
        }
    }
}
