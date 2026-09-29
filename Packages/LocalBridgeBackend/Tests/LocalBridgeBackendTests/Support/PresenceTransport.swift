import Foundation
import GChatBridgeCore
@testable import LocalBridgeBackend

/// A session whose `get_user_presence` answers are scripted one poll at a
/// time. The world, the shell and the directory come from the caller; every
/// other `/api/` call answers empty, and the channel never opens.
actor PresenceTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Boom: Error {}

    /// One poll's answer: people and their wire presence, or a failure.
    enum Answer {
        case people([String: GChatBridgeCore.Presence])
        case failure
    }

    private let shell, world: HTTPResponse
    private var answers: [Answer]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var pollsToHold: Int

    /// Every `get_user_presence` request, in the order it was sent.
    private(set) var polls: [GetUserPresenceRequest] = []

    /// `answers` are used in order; once they run out, the last one repeats.
    init(shell: HTTPResponse, world: HTTPResponse, answers: [Answer], heldPolls: Int = 0) {
        self.shell = shell
        self.world = world
        self.answers = answers
        pollsToHold = heldPolls
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
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    private func answerPoll(_ request: HTTPRequest) async throws -> HTTPResponse {
        try polls.append(GetUserPresenceRequest(serializedBytes: request.body ?? Data()))
        if pollsToHold > 0 {
            pollsToHold -= 1
            await withCheckedContinuation { held.append($0) }
        }
        let answer = answers.count > 1 ? answers.removeFirst() : answers.first
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

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}
