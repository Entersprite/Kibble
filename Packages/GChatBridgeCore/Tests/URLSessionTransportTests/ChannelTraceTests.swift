import Foundation
import GChatBridgeCore
import GChatBridgeCoreTestSupport
import Testing
@testable import URLSessionTransport

/// Records every `ChannelTraceSink` call synchronously, from whichever thread
/// `URLSessionTransport`'s body task happens to run on - `NSLock` guards it
/// the same way `ReachabilityBroadcaster` guards its own state, since a plain
/// array would race with the test's own reads once the body task and the test
/// are running concurrently.
///
/// File-scope rather than nested inside `ChannelTraceTests`: `Head`/`Ended`
/// nested one level inside *this* type is as deep as swiftlint's `nesting`
/// rule allows, so this type itself has to sit at the top level rather than
/// inside the suite.
private final class FakeChannelTraceSink: ChannelTraceSink, @unchecked Sendable {
    struct Head: Equatable {
        let status: Int
        let contentType: String?
        let contentEncoding: String?
        let transferEncoding: String?
    }

    struct Ended: Equatable {
        let outcome: ChannelTraceOutcome
        let totalBytes: Int
    }

    private let lock = NSLock()
    private var openedKindsStorage: [String] = []
    private var headsStorage: [Head] = []
    private var batchesStorage: [ChannelTraceBatch] = []
    private var endedStorage: [Ended] = []

    var openedKinds: [String] {
        lock.withLock { openedKindsStorage }
    }

    var heads: [Head] {
        lock.withLock { headsStorage }
    }

    var batches: [ChannelTraceBatch] {
        lock.withLock { batchesStorage }
    }

    var ended: [Ended] {
        lock.withLock { endedStorage }
    }

    func streamOpened(kind: String, at instant: ContinuousClock.Instant) {
        lock.withLock { openedKindsStorage.append(kind) }
    }

    func responseHeadReceived(
        status: Int,
        contentType: String?,
        contentEncoding: String?,
        transferEncoding: String?,
        at instant: ContinuousClock.Instant
    ) {
        lock.withLock {
            headsStorage.append(Head(
                status: status,
                contentType: contentType,
                contentEncoding: contentEncoding,
                transferEncoding: transferEncoding
            ))
        }
    }

    func batchArrived(_ batch: ChannelTraceBatch) {
        lock.withLock { batchesStorage.append(batch) }
    }

    func streamEnded(outcome: ChannelTraceOutcome, totalBytes: Int, at instant: ContinuousClock.Instant) {
        lock.withLock { endedStorage.append(Ended(outcome: outcome, totalBytes: totalBytes)) }
    }
}

/// `URLSessionTransport.stream()` is the one place `ChannelTraceSink` is ever
/// called - see `ChannelTrace.swift`'s own header for why this instrument
/// exists at all (`findings.md` §12.4). These tests drive it through
/// `StubURLProtocol`, the same as `URLSessionTransportTests`, and assert on a
/// fake sink rather than a real file - `ChannelTraceFileSink` itself is a
/// thin, deliberately untested boundary, the same shape this repo already
/// accepts for `SecItem` and `WKWebView`.
@Suite("Channel trace")
struct ChannelTraceTests {
    let stub = StubSession()

    private func drain(_ stream: HTTPStream) async throws -> Data {
        var body = Data()
        for try await chunk in stream.body {
            body.append(chunk)
        }
        return body
    }

    // MARK: - The happy path

    @Test("a completed stream reports open, head and a clean end")
    func streamReportsOpenHeadAndEnd() async throws {
        stub.enqueue(.init(status: 200, body: Data("hello".utf8), headers: ["Content-Type": "text/plain"]))
        let sink = FakeChannelTraceSink()
        let transport = URLSessionTransport(session: stub.session, channelTrace: sink)

        let stream = try await transport.stream(HTTPRequest(url: stub.baseURL, traceLabel: "handshake"))
        _ = try await drain(stream)

        #expect(sink.openedKinds == ["handshake"])
        #expect(sink.heads.first?.status == 200)
        #expect(sink.heads.first?.contentType == "text/plain")
        #expect(sink.ended.first?.outcome == .eof)
        #expect(sink.ended.first?.totalBytes == 5)
    }

    /// **The decisive assertion this whole instrument exists for**: a small,
    /// effectively-instantaneous body (as `StubURLProtocol` always delivers,
    /// with no artificial delay) arrives as exactly one batch, since nothing
    /// separates its bytes by more than `ChannelTraceBatcher.gapThreshold`.
    /// The gap-detection arithmetic itself is `ChannelTraceBatcherTests`'
    /// job; this only proves `stream()` actually wires real byte arrivals
    /// into it end to end.
    @Test("a small body arrives as exactly one batch carrying every byte")
    func aSmallBodyIsOneBatch() async throws {
        stub.enqueue(.init(status: 200, body: Data("hello".utf8)))
        let sink = FakeChannelTraceSink()
        let transport = URLSessionTransport(session: stub.session, channelTrace: sink)

        _ = try await drain(transport.stream(HTTPRequest(url: stub.baseURL)))

        #expect(sink.batches.count == 1)
        #expect(sink.batches.first?.byteCount == 5)
        #expect(sink.batches.first?.gapSincePrevious == .zero)
    }

    @Test("an empty body reports zero total bytes and no batches")
    func anEmptyBodyReportsNoBatches() async throws {
        stub.enqueue(.init(status: 200, body: Data()))
        let sink = FakeChannelTraceSink()
        let transport = URLSessionTransport(session: stub.session, channelTrace: sink)

        _ = try await drain(transport.stream(HTTPRequest(url: stub.baseURL)))

        #expect(sink.batches.isEmpty)
        #expect(sink.ended.first?.totalBytes == 0)
    }

    // MARK: - The decisive field

    /// This is the one header value the whole investigation turns on -
    /// `ChannelTraceSink.responseHeadReceived`'s own doc comment says so.
    /// This test only proves it reaches the sink unmodified; deciding what it
    /// *means* is the report's job, not this suite's.
    @Test("Content-Type reaches the sink exactly as the server sent it")
    func contentTypeReachesTheSink() async throws {
        stub.enqueue(.init(status: 200, body: Data(), headers: ["Content-Type": "application/json"]))
        let sink = FakeChannelTraceSink()
        let transport = URLSessionTransport(session: stub.session, channelTrace: sink)

        _ = try await drain(transport.stream(HTTPRequest(url: stub.baseURL)))

        #expect(sink.heads.first?.contentType == "application/json")
    }

    @Test("absent Content-Encoding and Transfer-Encoding report as nil, not empty strings")
    func absentHeadersReportAsNil() async throws {
        stub.enqueue(.init(status: 200, body: Data()))
        let sink = FakeChannelTraceSink()
        let transport = URLSessionTransport(session: stub.session, channelTrace: sink)

        _ = try await drain(transport.stream(HTTPRequest(url: stub.baseURL)))

        #expect(sink.heads.first?.contentEncoding == nil)
        #expect(sink.heads.first?.transferEncoding == nil)
    }

    // MARK: - Kind labelling

    @Test("a request with no traceLabel reports \"unlabeled\", not a crash or a guess")
    func noLabelReportsUnlabeled() async throws {
        stub.enqueue(.init(status: 200, body: Data()))
        let sink = FakeChannelTraceSink()
        let transport = URLSessionTransport(session: stub.session, channelTrace: sink)

        _ = try await drain(transport.stream(HTTPRequest(url: stub.baseURL)))

        #expect(sink.openedKinds == ["unlabeled"])
    }

    // MARK: - Failure

    /// A stream that fails before `session.bytes(for:)` even returns still
    /// reports that it was opened - `streamOpened` fires first, unconditionally -
    /// but nothing about a head or an end, because neither ever happened.
    @Test("a stream that fails before headers arrive reports only that it opened")
    func earlyFailureReportsOnlyOpened() async throws {
        stub.enqueueFailure(.timedOut)
        let sink = FakeChannelTraceSink()
        let transport = URLSessionTransport(session: stub.session, channelTrace: sink)

        await #expect(throws: (any Error).self) {
            _ = try await transport.stream(HTTPRequest(url: stub.baseURL, traceLabel: "reopen"))
        }

        #expect(sink.openedKinds == ["reopen"])
        #expect(sink.heads.isEmpty)
        #expect(sink.ended.isEmpty)
    }

    // MARK: - Nothing changes with no sink

    /// The whole "opt-in, dark by default" contract in one assertion: a
    /// `nil` sink (every construction site but the one `--probe=channeltrace`
    /// builds) must not change what `stream()` delivers.
    @Test("with no sink configured, the stream's body is unaffected")
    func noSinkChangesNothing() async throws {
        stub.enqueue(.init(status: 200, body: Data("unchanged".utf8)))
        let transport = URLSessionTransport(session: stub.session)
        let body = try await drain(transport.stream(HTTPRequest(url: stub.baseURL)))
        #expect(String(decoding: body, as: UTF8.self) == "unchanged")
    }

    // MARK: - traceLabel never touches the wire

    /// `HTTPRequest.traceLabel` is metadata for this instrument alone -
    /// `HTTPTransport.swift`'s own doc comment on the field says so. This is
    /// the regression test for that claim: a distinctive marker placed in
    /// `traceLabel` must never appear anywhere in the actual request
    /// `URLSessionTransport` sends.
    @Test("traceLabel never reaches the wire, on send or on stream")
    func traceLabelNeverReachesTheWire() async throws {
        stub.enqueue(.init(status: 200, body: Data()))
        stub.enqueue(.init(status: 200, body: Data()))
        let transport = URLSessionTransport(session: stub.session)
        let marker = "SECRET-TRACE-LABEL-MARKER"

        _ = try await transport.send(HTTPRequest(url: stub.baseURL, traceLabel: marker))
        _ = try await drain(transport.stream(HTTPRequest(url: stub.baseURL, traceLabel: marker)))

        for request in stub.requests {
            #expect(request.url?.absoluteString.contains(marker) != true)
            let headerValues = request.allHTTPHeaderFields?.values.joined(separator: " ") ?? ""
            #expect(!headerValues.contains(marker))
        }
    }
}
