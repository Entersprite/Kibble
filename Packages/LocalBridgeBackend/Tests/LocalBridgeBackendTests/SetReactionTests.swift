import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `send(_:)` for `.setReaction`, reached through a real `connect()`.
private actor RoutingTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let reaction: HTTPResponse
    private let reactionFailure: (any Error)?
    private(set) var sent: [HTTPRequest] = []

    init(
        shell: HTTPResponse,
        reaction: HTTPResponse = HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data()),
        reactionFailure: (any Error)? = nil
    ) {
        self.shell = shell
        self.reaction = reaction
        self.reactionFailure = reactionFailure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/update_reaction") {
            if let reactionFailure {
                throw reactionFailure
            }
            return reaction
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SetReactionTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private func shellResponse() -> HTTPResponse {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    private func accepted() throws -> HTTPResponse {
        var response = UpdateReactionResponse()
        // One field, so the body is not empty: `ProtoAPIClient` answers
        // `.emptyBody` for zero bytes.
        response.groupRevision.timestamp = 1
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private func command(
        conversation: String? = "space/s-1", thread: String? = "t-1", add: Bool = true,
        custom: CustomEmojiRef? = nil, messageID: String = "m-1", emoji: String = "👍"
    ) -> ChatCommand {
        .setReaction(
            messageID: Message.ID(messageID), emoji: custom?.displayText ?? emoji, add: add,
            conversationID: conversation.map { Conversation.ID($0) },
            threadID: thread.map { MessageThread.ID($0) },
            customEmoji: custom
        )
    }

    @Test func theBackendAdvertisesReactions() {
        let backend = LocalBridgeBackend(
            cookies: Self.cookies,
            transport: RoutingTransport(shell: shellResponse())
        )
        #expect(backend.capabilities.canReact)
        #expect(!backend.capabilities.canFetchCustomEmoji)
    }

    /// The bytes on the wire are `ReactionRequests.updateReaction`'s own, so an
    /// edit to what production sends cannot pass silently.
    @Test func aUnicodeReactionPostsTheRequestShape() async throws {
        let transport = try RoutingTransport(shell: shellResponse(), reaction: accepted())
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        try await backend.send(command())
        let request = try #require(await transport.sent
            .first { $0.url.path.contains("/api/update_reaction") })
        let body = try #require(request.body)
        let decoded = try UpdateReactionRequest(serializedBytes: body)
        let expected = try ReactionRequests.updateReaction(
            group: #require(ChannelEventMapping.groupID(for: Conversation.ID("space/s-1"))),
            topicID: "t-1", messageID: "m-1", emoji: .unicode("👍"), add: true
        )
        #expect(decoded.messageID == expected.messageID)
        #expect(decoded.emoji == expected.emoji)
        #expect(decoded.type == expected.type)
    }

    @Test func aCustomReactionSendsItsUUID() async throws {
        let transport = try RoutingTransport(shell: shellResponse(), reaction: accepted())
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        try await backend.send(command(add: false, custom: CustomEmojiRef(id: "e-1", shortcode: ":parrot:")))
        let request = try #require(await transport.sent
            .first { $0.url.path.contains("/api/update_reaction") })
        let decoded = try UpdateReactionRequest(serializedBytes: #require(request.body))
        #expect(decoded.emoji.customEmoji.uuid == "e-1")
        #expect(decoded.type == .remove)
    }

    /// Review Focus 4: an address that cannot be built fails before the
    /// network, never as an empty `MessageId`.
    @Test(arguments: [
        (String?.none, Optional("t-1")),
        (Optional("space/s-1"), String?.none),
        (Optional("s-1"), Optional("t-1")),
        (Optional("space/s-1"), Optional(""))
    ])
    func anUnaddressableCommandSendsNothing(_ conversation: String?, _ thread: String?) async throws {
        let transport = try RoutingTransport(shell: shellResponse(), reaction: accepted())
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            try await backend.send(command(conversation: conversation, thread: thread))
        }
        #expect(await transport.sent.allSatisfy { !$0.url.path.contains("/api/update_reaction") })
    }

    /// Finding 1 (review round 1, Important): an empty message id, an empty
    /// emoji with no custom emoji, or a custom emoji with an empty id must
    /// each fail before the network, never reach `/api/update_reaction`
    /// carrying the empty field.
    @Test(arguments: [
        ("", "👍", String?.none),
        ("m-1", "", String?.none),
        ("m-1", "👍", Optional(""))
    ])
    func anEmptyFieldSendsNothing(_ messageID: String, _ emoji: String, _ customID: String?) async throws {
        let transport = try RoutingTransport(shell: shellResponse(), reaction: accepted())
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        let custom = customID.map { CustomEmojiRef(id: $0, shortcode: ":parrot:") }
        await #expect(throws: ChatError.self) {
            try await backend.send(command(custom: custom, messageID: messageID, emoji: emoji))
        }
        #expect(await transport.sent.allSatisfy { !$0.url.path.contains("/api/update_reaction") })
    }

    @Test func aFailedCallThrows() async throws {
        let transport = RoutingTransport(shell: shellResponse(), reactionFailure: URLError(.timedOut))
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        await #expect(throws: ChatError.self) { try await backend.send(command()) }
    }

    @Test func beforeConnectingNothingIsSent() async throws {
        let transport = try RoutingTransport(shell: shellResponse(), reaction: accepted())
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        await #expect(throws: ChatError.self) { try await backend.send(command()) }
        #expect(await transport.sent.isEmpty)
    }
}
