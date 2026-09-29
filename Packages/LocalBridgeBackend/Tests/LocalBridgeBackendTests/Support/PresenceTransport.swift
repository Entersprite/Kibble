import Foundation
import GChatBridgeCore
@testable import LocalBridgeBackend

/// A session whose `get_user_presence` answers are scripted one poll at a
/// time. The world and the shell come from the caller. `get_members` names
/// everyone it is asked about, and can be held. The channel either never
/// opens, or is held and then fails terminally.
actor PresenceTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Boom: Error {}

    /// One poll's answer: people and their wire presence, or a failure.
    enum Answer {
        case people([String: GChatBridgeCore.Presence])
        case failure
    }

    private let shell, world: HTTPResponse
    private let topics: HTTPResponse?
    private let holdPollAt: Int?
    private var answers: [Answer]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var pollsToHold: Int
    private var lookupsToHold: Int
    private let terminalStream: Bool
    private var streamGate: CheckedContinuation<Void, Never>?
    private var streamOpened = false

    /// Every `get_user_presence` request, in the order it was sent.
    private(set) var polls: [GetUserPresenceRequest] = []
    /// How many of those have been answered or failed - so a test can wait
    /// for a released answer to be back rather than for a fixed time.
    private(set) var pollsAnswered = 0
    /// How many `get_members` calls have been answered.
    private(set) var lookupsAnswered = 0

    /// `answers` are used in order; once they run out, the last one repeats.
    init(
        shell: HTTPResponse,
        world: HTTPResponse,
        answers: [Answer],
        heldPolls: Int = 0,
        heldLookups: Int = 0,
        terminalStream: Bool = false,
        topics: HTTPResponse? = nil,
        holdPollAt: Int? = nil
    ) {
        self.shell = shell
        self.world = world
        self.topics = topics
        self.holdPollAt = holdPollAt
        self.answers = answers
        pollsToHold = heldPolls
        lookupsToHold = heldLookups
        self.terminalStream = terminalStream
    }

    /// Lets a held terminal stream answer its 403.
    func openStream() {
        streamOpened = true
        streamGate?.resume()
        streamGate = nil
    }

    func release() {
        for continuation in held {
            continuation.resume()
        }
        held = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        if path.contains("/mole/world") {
            return shell
        }
        if path.contains("/api/paginated_world") {
            return world
        }
        if path.contains("/api/get_user_presence") {
            return try await answerPoll(request)
        }
        if path.contains("/api/get_members") {
            return try await answerLookup(request)
        }
        if path.contains("/api/list_topics"), let topics {
            return topics
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    private func answerPoll(_ request: HTTPRequest) async throws -> HTTPResponse {
        try polls.append(GetUserPresenceRequest(serializedBytes: request.body ?? Data()))
        if pollsToHold > 0 || polls.count - 1 == holdPollAt {
            pollsToHold = max(0, pollsToHold - 1)
            await withCheckedContinuation { held.append($0) }
        }
        let answer = answers.count > 1 ? answers.removeFirst() : answers.first
        pollsAnswered += 1
        guard case let .people(people)? = answer else { throw Boom() }
        var response = GetUserPresenceResponse()
        response.userPresences = people.keys.sorted().map { id in
            var entry = UserPresence()
            entry.userID.id = id
            entry.presence = people[id] ?? .undefinedPresence
            return entry
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// Everyone asked about, named after their id.
    private func answerLookup(_ request: HTTPRequest) async throws -> HTTPResponse {
        let asked = try GetMembersRequest(serializedBytes: request.body ?? Data())
        if lookupsToHold > 0 {
            lookupsToHold -= 1
            await withCheckedContinuation { held.append($0) }
        }
        var response = GetMembersResponse()
        response.members = asked.memberIds.map { memberID in
            var user = User()
            user.userID = memberID.userID
            user.name = "Person \(memberID.userID.id)"
            var member = GChatBridgeCore.Member()
            member.user = user
            return member
        }
        lookupsAnswered += 1
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        guard terminalStream else { throw NoStream() }
        // Held until `openStream()`, so a test can start the poll while the
        // channel is still alive. 403 is terminal, not retried.
        if !streamOpened {
            await withCheckedContinuation { streamGate = $0 }
        }
        let empty = AsyncThrowingStream<Data, any Error> { $0.finish() }
        return HTTPStream(status: 403, headers: HTTPHeaders([]), body: empty)
    }
}
