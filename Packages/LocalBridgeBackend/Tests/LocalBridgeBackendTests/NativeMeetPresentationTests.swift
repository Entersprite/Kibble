import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetPresentationTests {
    @Test func separatePresenterRegistersOnlyVideoAndLeavesWithoutChangingVoice() async throws {
        let transport = try ScriptedTransport(responses())
        let main = VideoFakeMedia(), child = VideoFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: main)
        try await session.connect()
        await cancelPoll(session)
        let start = try #require(main.shareStart), stop = try #require(main.shareStop)
        try await start(child)
        #expect(child.requests.count == 2)
        for request in child.requests {
            let variant = try #require(ProtoFieldScan.fields(in: request).fields
                .first { [2, 4].contains($0.number) })
            let operation = try #require(ProtoFieldScan.payloads(ofField: variant.number, in: request).first)
            let stream = try #require(ProtoFieldScan.payloads(ofField: 4, in: operation).first)
            #expect(ProtoFieldScan.varintValues(ofField: 2, in: stream) == [2])
            #expect(ProtoFieldScan.payloads(ofField: 3, in: stream).first == Data("presenter".utf8))
        }
        let stopped = await stop()
        #expect(stopped)
        #expect(child.closed)
        #expect(!main.closed)
        #expect(await session.ready)
        #expect(await session.audioStream != nil)
        await session.close()
        let sent = await transport.sent
        #expect(sent.count == 10)
        #expect(!sent.contains { $0.url.path.contains("MeetingInvite") })
        #expect(sent[4].url.path.hasSuffix("CreateTokenForSecondary"))
        #expect(sent[4].body == Data([0x0A, 0x0B] + Array("spaces/demo".utf8)))
        #expect(sent[4].headers["x-goog-meeting-token"] == "30;joined")
        #expect(sent[6].url.path.hasSuffix("CreateMeetingDevice"))
        #expect(sent[6].headers["x-goog-meeting-token"] == "15;secondary-credential")
        #expect(main.shareStart == nil)
        await #expect(throws: (any Error).self) { try await start(VideoFakeMedia()) }
    }

    @Test func presenterRegistrationFailureClosesOnlyTheChildAndLeavesItOnce() async throws {
        let transport = try ScriptedTransport(responses())
        let main = VideoFakeMedia(), child = VideoFakeMedia()
        child.failVideo = true
        let session = try await NativeMeetFixture.session(transport, media: main)
        try await session.connect(); await cancelPoll(session)
        let start = try #require(main.shareStart)
        await #expect(throws: (any Error).self) { try await start(child) }
        #expect(child.closed)
        #expect(!main.closed)
        #expect(await session.ready)
        #expect(await session.presentation == nil)
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("stream registration failed"))
        #expect(!report.contains("secondary-credential"))
        await session.close()
        #expect(await transport.sent.count == 10)
    }

    @Test func closingDuringAcceptedChildRegistrationSettlesBeforeBothLeaves() async throws {
        let base = try ScriptedTransport(responses(childJoins: false))
        let transport = HeldPresenterTransport(base: base)
        let main = VideoFakeMedia(), child = VideoFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: main)
        try await session.connect(); await cancelPoll(session)
        let start = try #require(main.shareStart)
        let starting = Task { try await start(child) }
        for _ in 0 ..< 2000 {
            if await transport.held {
                break
            }
            await Task.yield()
        }
        #expect(await transport.held)
        let closing = Task { await session.close() }
        for _ in 0 ..< 2000 {
            if main.closed {
                break
            }
            await Task.yield()
        }
        #expect(main.closed)
        await transport.release()
        _ = await starting.result
        await closing.value
        #expect(child.closed)
        #expect(await session.presentation == nil)
        let sent = await base.sent
        #expect(sent.count == 9)
        #expect(sent.suffix(2).allSatisfy { $0.url.path.hasSuffix("UpdateMeetingDevice") })
    }

    @Test func failedPresenterLeaveSurvivesRepeatedStopAndNeverEndsVoice() async throws {
        var responses = try responses()
        responses[8] = .success(HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data()))
        let transport = ScriptedTransport(responses)
        let main = VideoFakeMedia(), child = VideoFakeMedia()
        child.failVideo = true
        let session = try await NativeMeetFixture.session(transport, media: main)
        try await session.connect(); await cancelPoll(session)
        let start = try #require(main.shareStart), stop = try #require(main.shareStop)
        await #expect(throws: (any Error).self) { try await start(child) }
        let first = await stop(), second = await stop()
        #expect(!first && !second)
        #expect(await session.cleanupStatus.leaveUnconfirmed)
        #expect(!main.closed)
        #expect(child.closed)
        #expect(await transport.sent.count == 9)
        await session.close()
        #expect(await transport.sent.count == 10)
    }

    @Test func closingDuringSecondaryAuthorizationSettlesBeforeParentLeaveAndNeverCreatesAChild(
    ) async throws {
        let original = try responses()
        let replies = try Array(original.prefix(5)) + [#require(original.last)]
        let base = ScriptedTransport(replies)
        let transport = HeldPresenterTransport(base: base, holdsToken: true)
        let main = VideoFakeMedia(), child = VideoFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: main)
        try await session.connect(); await cancelPoll(session)
        let start = try #require(main.shareStart)
        let starting = Task { try await start(child) }
        for _ in 0 ..< 2000 {
            if await transport.held {
                break
            }
            await Task.yield()
        }
        #expect(await transport.held)
        let closing = Task { await session.close() }
        for _ in 0 ..< 2000 {
            if main.closed {
                break
            }
            await Task.yield()
        }
        #expect(main.closed)
        #expect(await base.sent.count == 5)
        await transport.release()
        _ = await starting.result
        await closing.value
        let sent = await base.sent
        #expect(sent.count == 6)
        #expect(sent[5].url.path.hasSuffix("UpdateMeetingDevice"))
        #expect(child.requests.isEmpty)
        #expect(await session.presentation == nil)
        #expect(await session.cleanupStatus.isConfirmed)
    }

    private func cancelPoll(_ session: NativeMeetCallSession) async {
        let poll = await session.videoPoll; poll?.cancel(); _ = await poll?.result
    }

    private func responses(childJoins: Bool = true) throws -> [Result<HTTPResponse, any Error>] {
        let original = NativeMeetFixture.responses(video: true)
        let media = try original[1].get()
        let decoded = try #require(Data(base64Encoded: media.body))
        let config = try #require(ProtoFieldScan.payloads(ofField: 2, in: decoded).first)
        func device(_ state: UInt64) -> Result<HTTPResponse, any Error> {
            NativeMeetFixture.ok(NativeMeetFixture.string(1, "spaces/demo/devices/presenter")
                + NativeMeetFixture.number(4, state)
                + NativeMeetFixture.string(21, "spaces/demo/devices/one")
                + NativeMeetFixture.number(25, state == 2 ? 1 : 2))
        }
        let child = [
            NativeMeetFixture.ok(NativeMeetFixture.string(1, "15;secondary-credential")),
            NativeMeetFixture.ok(NativeMeetFixture.string(1, "mediasessions/presenter")
                + NativeMeetFixture.bytes(2, config)),
            device(2)
        ]
            + (childJoins ? [device(1)] : []) + [device(6)]
        return (Array(original.prefix(4)) + child + [original[4]]).map { result in
            result.map { HTTPResponse(
                status: $0.status,
                headers: HTTPHeaders(fields: $0.headers.fields + [.init(
                    name: "x-goog-meeting-debugid",
                    value: "conference"
                )]),
                body: $0.body
            ) }
        }
    }
}

private actor HeldPresenterTransport: HTTPTransport {
    let base: ScriptedTransport
    var count = 0
    let holdsToken: Bool
    private(set) var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: ScriptedTransport, holdsToken: Bool = false) {
        self.base = base; self.holdsToken = holdsToken
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let result = try await base.send(request)
        if holdsToken, request.url.path.hasSuffix("CreateTokenForSecondary") {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        if !holdsToken, request.url.path.hasSuffix("CreateMeetingDevice") {
            count += 1
            if count == 2 {
                held = true
                await withCheckedContinuation { continuation = $0 }
            }
        }
        return result
    }

    func release() {
        continuation?.resume(); continuation = nil
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }
}
