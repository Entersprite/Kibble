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

    init(shell: HTTPResponse, answer: GChatBridgeCore.Message?) {
        self.shell = shell
        self.answer = answer
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
        #expect(await reactionChanges(log.settle()).isEmpty)
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
}
