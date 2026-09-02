import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `resolveAndEmitSelf`, reached through a real `connect()` - split out of
/// `LiveChannelTests.swift` for the same reason
/// `LoadConversationsMemberResolutionTests.swift` was split out of
/// `LoadConversationsTests.swift`: a transport shaped for this one concern
/// rather than one shared shape drifting to fit several.
private actor RoutingTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let selfStatusResponse: HTTPResponse
    private let selfStatusFailure: (any Error)?

    init(
        shell: HTTPResponse,
        selfStatusResponse: HTTPResponse,
        selfStatusFailure: (any Error)? = nil
    ) {
        self.shell = shell
        self.selfStatusResponse = selfStatusResponse
        self.selfStatusFailure = selfStatusFailure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/get_self_user_status") {
            if let selfStatusFailure {
                throw selfStatusFailure
            }
            return selfStatusResponse
        }
        // The channel's register()/acknowledge() - neither inspects the
        // response body, so a bare 200 is enough.
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        // Ends the channel quickly and on purpose - this suite is not testing
        // it, and a channel that never closes would leave nothing to compare
        // its own concurrent, unrelated chatter against.
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SelfIdentificationTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private func shellResponse(app: String = "DynamiteWebUi") -> HTTPResponse {
        let html = LocalBridgeBackendTests.shell(app: app)
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    /// A `GetSelfUserStatusResponse` carrying only an id - `get_self_user_status`
    /// never returns a name, and this fixture should not pretend otherwise.
    private func selfStatusResponse(id: String) throws -> HTTPResponse {
        var userID = UserId()
        userID.id = id
        var userStatus = UserStatus()
        userStatus.userID = userID
        var response = GetSelfUserStatusResponse()
        response.userStatus = userStatus
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private func backend(
        selfStatusResponse: HTTPResponse,
        selfStatusFailure: (any Error)? = nil
    ) -> LocalBridgeBackend {
        LocalBridgeBackend(
            cookies: Self.cookies,
            transport: RoutingTransport(
                shell: shellResponse(),
                selfStatusResponse: selfStatusResponse,
                selfStatusFailure: selfStatusFailure
            )
        )
    }

    /// Collects every event emitted within `duration`, rather than a fixed
    /// count - same shape and same reasoning as
    /// `LoadConversationsMemberResolutionTests.collectEvents`:
    /// `resolveAndEmitSelf()` races the channel's own concurrent, unrelated
    /// failure (`RoutingTransport.stream()` always throws `NoStream`), so a
    /// fixed count assumes an ordering this scenario does not actually
    /// guarantee.
    private func collectEvents(
        _ backend: LocalBridgeBackend,
        for duration: Duration = .milliseconds(200)
    ) async -> [ChatEvent] {
        let collector = Task<[ChatEvent], Never> {
            var events: [ChatEvent] = []
            for await event in backend.events {
                events.append(event)
            }
            return events
        }
        try? await Task.sleep(for: duration)
        collector.cancel()
        return await collector.value
    }

    // MARK: - Success

    /// The discriminating test: a successful `get_self_user_status` call
    /// emits `.selfIdentified` carrying exactly the id the response named and
    /// `kind: .human` - never a name, because the call does not return one.
    /// Deliberately breaking the `emit(.selfIdentified(...))` call in
    /// `resolveAndEmitSelf` and re-running this turns it red - see the slice
    /// report for the exact failure text that produced.
    @Test func connectEmitsSelfIdentifiedWithTheIDFromTheResponse() async throws {
        let backend = try backend(selfStatusResponse: selfStatusResponse(id: "u-me"))
        try await backend.connect()

        let events = await collectEvents(backend)
        #expect(events.contains {
            $0 == .selfIdentified(ChatKit.Member(id: ChatKit.Member.ID("u-me"), kind: .human))
        })
    }

    // MARK: - Failure

    /// `connect()` must not fail because self-identification failed - a
    /// degraded title is not a broken session. Not throwing is the whole
    /// assertion.
    @Test func connectSucceedsEvenWhenSelfIdentificationFails() async throws {
        struct Boom: Error {}
        let backend = try backend(
            selfStatusResponse: selfStatusResponse(id: "unused"),
            selfStatusFailure: Boom()
        )
        try await backend.connect()
    }

    /// The failure above must not vanish silently either - same shape as
    /// `LoadConversationsMemberResolutionTests.loadConversationsEmitsABackendErrorWhenMemberResolutionFails`.
    @Test func aFailedSelfIdentificationCallIsReportedAsABackendError() async throws {
        struct Boom: Error {}
        let backend = try backend(
            selfStatusResponse: selfStatusResponse(id: "unused"),
            selfStatusFailure: Boom()
        )
        try await backend.connect()

        let events = await collectEvents(backend)
        #expect(events.contains {
            if case let .backendError(error) = $0, case .transport = error {
                true
            } else {
                false
            }
        })
    }

    /// An empty id is not an identity worth rendering as "you" - nothing is
    /// emitted as `.selfIdentified`, and the gap is reported instead.
    @Test func anEmptyIDDoesNotEmitSelfIdentified() async throws {
        let backend = try backend(selfStatusResponse: selfStatusResponse(id: ""))
        try await backend.connect()

        let events = await collectEvents(backend)
        #expect(!events.contains {
            if case .selfIdentified = $0 {
                true
            } else {
                false
            }
        })
        #expect(events.contains {
            if case let .backendError(.unknown(message)) = $0 {
                message.contains("get_self_user_status")
            } else {
                false
            }
        })
    }
}
