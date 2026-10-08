import Foundation
import GChatBridgeCore
@testable import LocalBridgeBackend

/// A session whose `GetAssistiveFeatures` answers are scripted one request at
/// a time. Everything else a connected backend asks for is answered well
/// enough to stay out of the way: the shell (with the Punctual key unless
/// `key` is `nil`), a world of one-to-one DMs between `u-me` and each partner
/// (a DM of more than two maps to a group DM, which the poll does not ask
/// about), names for everyone, the local user `u-me`, and presence for `u-1`.
/// The channel never opens.
actor CalendarTransport: HTTPTransport {
    struct NoStream: Error {}

    enum Answer {
        case json(String)
        case failure
    }

    private let key: String?
    private let partners: [String]
    private var answers: [Answer]
    private var lookupsToHold: Int
    private let holdCalendarAt: Int?
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Every `GetAssistiveFeatures` request, in order.
    private(set) var calendarRequests: [HTTPRequest] = []
    private(set) var calendarAnswered = 0

    /// `answers` are used in order; once they run out, the last one repeats.
    init(
        key: String? = "tzliq-key",
        partners: [String] = ["u-1"],
        answers: [Answer],
        heldLookups: Int = 0,
        holdCalendarAt: Int? = nil
    ) {
        self.key = key
        self.partners = partners
        self.answers = answers
        lookupsToHold = heldLookups
        self.holdCalendarAt = holdCalendarAt
    }

    func release() {
        for continuation in held {
            continuation.resume()
        }
        held = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        if path.contains("GetAssistiveFeatures") {
            return await answerCalendar(request)
        }
        if path.contains("/mole/world") {
            return Self.ok(Data(Self.shell(key: key).utf8))
        }
        if path.contains("/api/paginated_world") {
            return try Self.ok(Self.world(partners).serializedBytes())
        }
        if path.contains("/api/get_members") {
            return try await answerLookup(request)
        }
        if path.contains("/api/get_self_user_status") {
            var response = GetSelfUserStatusResponse()
            response.userStatus.userID.id = "u-me"
            return try Self.ok(response.serializedBytes())
        }
        if path.contains("/api/get_user_presence") {
            var response = GetUserPresenceResponse()
            var entry = UserPresence()
            entry.userID.id = "u-1"
            entry.presence = .active
            response.userPresences = [entry]
            return try Self.ok(response.serializedBytes())
        }
        return Self.ok(Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }

    private func answerCalendar(_ request: HTTPRequest) async -> HTTPResponse {
        calendarRequests.append(request)
        if calendarRequests.count - 1 == holdCalendarAt {
            await withCheckedContinuation { held.append($0) }
        }
        let answer = answers.count > 1 ? answers.removeFirst() : answers.first
        calendarAnswered += 1
        guard case let .json(body)? = answer else {
            return HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data())
        }
        return Self.ok(Data(body.utf8))
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
            var member = GChatBridgeCore.Member()
            member.user.userID = memberID.userID
            member.user.name = "Person \(memberID.userID.id)"
            return member
        }
        return try Self.ok(response.serializedBytes())
    }

    private static func ok(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }

    private static func shell(key: String?) -> String {
        let extra = key.map { #","Tzliq":"\#($0)""# } ?? ""
        return """
        <script nonce="x">window.WIZ_global_data = ({"qwAQke":"DynamiteWebUi",\
        "SMqcke":"\(String(repeating: "t", count: 42))","cfb2h":"boq_x"\(extra)});</script>
        """
    }

    /// One DM with `u-me` per partner; with none, one space, because an
    /// empty answer is an empty body, which `ProtoAPIClient` rejects.
    private static func world(_ partners: [String]) -> PaginatedWorldResponse {
        var response = PaginatedWorldResponse()
        guard !partners.isEmpty else {
            var item = WorldItemLite()
            item.groupID.spaceID.spaceID = "s-1"
            response.worldItems = [item]
            return response
        }
        response.worldItems = partners.enumerated().map { index, partner in
            var item = WorldItemLite()
            item.groupID.dmID.dmID = "d-\(index)"
            item.dmMembers.members = ["u-me", partner].map { id in
                var userID = UserId()
                userID.id = id
                return userID
            }
            return item
        }
        return response
    }
}
