import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

private actor RefetchTransport: HTTPTransport {
    struct NoStream: Error {}
    private let shell: HTTPResponse
    private var answer: GChatBridgeCore.Message?
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var listMessagesCalls = 0
    /// How many more `stream()` calls answer terminally (a 403, which
    /// `ChannelFailure` treats as dead-credential rather than recoverable -
    /// see `LiveChannelFailureTests`'s own doc comment on the same status).
    /// Decremented on every call; once it reaches zero, `stream()` reverts to
    /// throwing `NoStream`, which is recoverable and retries harmlessly in
    /// the background - the second connect in a reconnect test must not go
    /// terminal again and re-forget state out from under the fetch it is
    /// trying to observe.
    private var terminalStreamsLeft: Int

    init(shell: HTTPResponse, answer: GChatBridgeCore.Message?, terminalStreams: Int = 0) {
        self.shell = shell
        self.answer = answer
        terminalStreamsLeft = terminalStreams
    }

    func hold(_ value: Bool) {
        holding = value
    }

    func release() {
        held.forEach { $0.resume() }; held = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.contains("/mole/world") {
            return shell
        }
        guard request.url.path.contains("/api/list_messages") else {
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        }
        listMessagesCalls += 1
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        var response = ListMessagesResponse()
        if let answer {
            response.messages = [answer]
        }
        response.groupRevision.timestamp = 1
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        if terminalStreamsLeft > 0 {
            terminalStreamsLeft -= 1
            let empty = AsyncThrowingStream<Data, any Error> { $0.finish() }
            return HTTPStream(status: 403, headers: HTTPHeaders([]), body: empty)
        }
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ReactionRefetchTests: SenderResolutionFixtures {
    private func target() -> ReactedMessage {
        var parent = MessageParentId()
        parent.topicID.topicID = "t-1"
        parent.topicID.groupID = spaceGroupID()
        return ReactedMessage(messageID: ChatKit.Message.ID("m-1"), parent: parent)
    }

    private func answer(reactions: [GChatBridgeCore.Reaction]) -> GChatBridgeCore.Message {
        var message = reply("m-1", from: "u-1")
        message.id.parentID.topicID.topicID = "t-1"
        message.reactions = reactions
        return message
    }

    private func thumbs(_ count: Int32) -> GChatBridgeCore.Reaction {
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.unicode = "👍"
        reaction.count = count
        return reaction
    }

    private func backend(_ transport: RefetchTransport, delay: Duration) -> LocalBridgeBackend {
        LocalBridgeBackend(
            cookies: Self.cookies, transport: transport, retry: .immediate, reactionRefetchDelay: delay
        )
    }

    private func reactionChanges(_ events: [ChatEvent]) -> [[ChatKit.Reaction]] {
        events.compactMap {
            if case let .reactionChanged(_, reactions) = $0 {
                reactions
            } else {
                nil
            }
        }
    }

    @Test func aRefetchEmitsTheServersCompleteSet() async throws {
        let transport = RefetchTransport(shell: shell(), answer: answer(reactions: [thumbs(2)]))
        let backend = backend(transport, delay: .zero)
        let log = SenderEventLog(backend)
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        let events = await log.settle()
        #expect(reactionChanges(events) == [[ChatKit.Reaction(emoji: "👍", count: 2)]])
        #expect(await transport.listMessagesCalls == 1)
    }

    /// Review Focus 4: a burst during the wait is one call.
    @Test func aBurstDuringTheWaitIsOneCall() async throws {
        let transport = RefetchTransport(shell: shell(), answer: answer(reactions: [thumbs(1)]))
        let backend = backend(transport, delay: .milliseconds(100))
        let log = SenderEventLog(backend)
        try await backend.connect()
        for _ in 0 ..< 5 {
            await backend.requestReactionRefetch(target())
        }
        _ = await log.settle()
        #expect(await transport.listMessagesCalls == 1)
    }

    /// A request while a fetch is in flight is answered by exactly one more.
    @Test func aRequestDuringAFetchIsOneMoreCall() async throws {
        let transport = RefetchTransport(shell: shell(), answer: answer(reactions: [thumbs(1)]))
        await transport.hold(true)
        let backend = backend(transport, delay: .zero)
        let log = SenderEventLog(backend)
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        _ = await log.settle()
        for _ in 0 ..< 3 {
            await backend.requestReactionRefetch(target())
        }
        await transport.hold(false)
        await transport.release()
        _ = await log.settle()
        #expect(await transport.listMessagesCalls == 2)
    }

    @Test func aMessageNotOnThePageEmitsNothing() async throws {
        let transport = RefetchTransport(shell: shell(), answer: nil)
        let backend = backend(transport, delay: .zero)
        let log = SenderEventLog(backend)
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        let events = await log.settle()
        // Positive control (Finding 3): without this, the test would also
        // pass if the refetch never ran at all.
        #expect(await transport.listMessagesCalls == 1)
        #expect(reactionChanges(events).isEmpty)
    }

    /// Review Focus 5.
    @Test func disconnectingDuringTheWaitEmitsNothingAndArmsNothing() async throws {
        let transport = RefetchTransport(shell: shell(), answer: answer(reactions: [thumbs(1)]))
        let backend = backend(transport, delay: .milliseconds(200))
        let log = SenderEventLog(backend)
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        await backend.disconnect()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await reactionChanges(log.settle()).isEmpty)
        #expect(await transport.listMessagesCalls == 0)
    }

    /// Finding 2 (fix round 1): `disconnectingDuringTheWaitEmitsNothingAndArmsNothing`
    /// cannot fail with `forgetReactionRefetches()` deleted from `disconnect()` -
    /// the generation guard alone already keeps that test's own window silent.
    /// This is the test that actually needs the call: without it, `phases[m-1]`
    /// stays `.waiting` across the reconnect, and a request for the same
    /// message afterwards is absorbed rather than started.
    @Test func aReconnectStartsFreshForTheSameMessage() async throws {
        let transport = RefetchTransport(shell: shell(), answer: answer(reactions: [thumbs(1)]))
        let backend = backend(transport, delay: .milliseconds(50))
        let log = SenderEventLog(backend)
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        await backend.disconnect()
        // Past the delay, bounded: lets the orphaned wait resolve (it finds a
        // generation mismatch either way) before the reconnect below.
        try? await Task.sleep(for: .milliseconds(100))
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        let events = await log.settle()
        #expect(await transport.listMessagesCalls == 1)
        #expect(reactionChanges(events) == [[ChatKit.Reaction(emoji: "👍", count: 1)]])
    }

    /// Finding 1 (fix round 1): a *terminal* channel stop must forget
    /// refetches too, not just bump the generation. `channelStopped` used to
    /// call only `forgetDirectory()`, which stops a stuck refetch from ever
    /// *emitting* but never clears `phases` - so a message stuck in
    /// `.waiting` when the channel dies stays stuck for the life of the
    /// backend: `disconnect()` afterwards returns early (already
    /// disconnected), and a later `connect()` resets nothing.
    ///
    /// `terminalStreams: 1` makes only the *first* `stream()` call answer
    /// with a dead-credential 403 (`LiveChannelFailureTests`'s own shape);
    /// the second connect's channel reverts to throwing `NoStream`, which is
    /// recoverable and retries harmlessly in the background rather than
    /// going terminal again and re-forgetting state out from under the
    /// fetch this test is trying to observe.
    @Test func aTerminalChannelStopForgetsAWaitingRefetch() async throws {
        let transport = RefetchTransport(
            shell: shell(), answer: answer(reactions: [thumbs(1)]), terminalStreams: 1
        )
        let backend = backend(transport, delay: .milliseconds(100))
        let log = SenderEventLog(backend)
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        // Waits for `channelStopped` to have fully run - the terminal 403
        // above is what drives it - so the state it leaves behind is settled
        // before the reconnect below.
        await backend.waitForChannel()
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        let events = await log.settle()
        #expect(await transport.listMessagesCalls == 1)
        #expect(reactionChanges(events) == [[ChatKit.Reaction(emoji: "👍", count: 1)]])
    }
}
