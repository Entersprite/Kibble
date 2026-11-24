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
    private var firstStreamIsTerminal: Bool
    private var terminalResponseReleased = false
    private var terminalResponse: CheckedContinuation<Void, Never>?

    init(shell: HTTPResponse, answer: GChatBridgeCore.Message?, firstStreamIsTerminal: Bool = false) {
        self.shell = shell
        self.answer = answer
        self.firstStreamIsTerminal = firstStreamIsTerminal
    }

    func hold(_ value: Bool) {
        holding = value
    }

    func release() {
        held.forEach { $0.resume() }; held = []
    }

    func releaseTerminalResponse() {
        terminalResponseReleased = true
        terminalResponse?.resume()
        terminalResponse = nil
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
        if firstStreamIsTerminal {
            firstStreamIsTerminal = false
            if !terminalResponseReleased {
                await withCheckedContinuation { terminalResponse = $0 }
            }
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

    /// Final review: the post-fetch `guard !Task.isCancelled, generation ==
    /// directoryGeneration` (after `await apiClient.call`) had no test. A
    /// fetch that was already in flight when `disconnect()` ran must not
    /// emit once Google finally answers it - the call was made for a session
    /// that no longer exists.
    @Test func disconnectingDuringAFetchEmitsNothing() async throws {
        let transport = RefetchTransport(shell: shell(), answer: answer(reactions: [thumbs(1)]))
        await transport.hold(true)
        let backend = backend(transport, delay: .zero)
        let log = SenderEventLog(backend)
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        // The fetch is in flight, held, by the time this returns.
        _ = await log.settle()
        await backend.disconnect()
        await transport.hold(false)
        await transport.release()
        let events = await log.settle()
        #expect(reactionChanges(events).isEmpty)
        #expect(await transport.listMessagesCalls == 1)
    }

    /// Final review, the clobber the guard's doc comment warns about: an old
    /// session's fetch, left running across a disconnect and reconnect, must
    /// not land on top of the new session's own refetch of the same message.
    /// Both calls answer the same way (`RefetchTransport` has one `answer`),
    /// so without the guard the old call's late response emits a second
    /// `.reactionChanged` and re-finishes a phase entry the new fetch is
    /// still using.
    @Test func reconnectingDuringAFetchDoesNotClobberTheNewSessionsRefetch() async throws {
        let transport = RefetchTransport(shell: shell(), answer: answer(reactions: [thumbs(1)]))
        await transport.hold(true)
        let backend = backend(transport, delay: .zero)
        let log = SenderEventLog(backend)
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        // The old session's fetch is in flight, held.
        _ = await log.settle()
        await backend.disconnect()
        try await backend.connect()
        await backend.requestReactionRefetch(target())
        // The new session's fetch is in flight too, held right behind it.
        _ = await log.settle()
        await transport.hold(false)
        await transport.release()
        let events = await log.settle()
        #expect(reactionChanges(events) == [[ChatKit.Reaction(emoji: "👍", count: 1)]])
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

    /// A terminal stop must cancel the waiting task and clear its phase so
    /// the next connection can start another refetch for the same message.
    @Test func aTerminalChannelStopForgetsAWaitingRefetch() async throws {
        let transport = RefetchTransport(
            shell: shell(), answer: answer(reactions: [thumbs(1)]), firstStreamIsTerminal: true
        )
        let backend = backend(transport, delay: .seconds(30))
        let target = target()
        try await backend.connect()
        await backend.requestReactionRefetch(target)
        let pending = await backend.reactionRefetches.tasks[target.messageID]
        await transport.releaseTerminalResponse()
        await backend.waitForChannel()
        let retired = try #require(pending)
        try #require(retired.isCancelled)
        await retired.value
        #expect(await backend.reactionRefetches.phases[target.messageID] == nil)
        #expect(await backend.reactionRefetches.tasks[target.messageID] == nil)

        try await backend.connect()
        await backend.requestReactionRefetch(target)
        let restarted = await backend.reactionRefetches.tasks[target.messageID]
        #expect(restarted?.isCancelled == false)
        await backend.disconnect()
        #expect(await transport.listMessagesCalls == 0)
    }
}
