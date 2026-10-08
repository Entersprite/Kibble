import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Answers the shell, `get_self_user_status` and the three status calls;
/// everything else gets an empty 200, as `SetReactionTests`' transport does.
private actor StatusTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Refused: Error {}

    static let calls = ["set_custom_status", "set_dnd_duration", "set_presence_shared"]

    private let selfStatus: UserStatus
    private let answer: UserStatus?
    private let refuses: Bool
    private(set) var sent: [HTTPRequest] = []

    init(selfStatus: UserStatus = UserStatus(), answer: UserStatus? = UserStatus(), refuses: Bool = false) {
        self.selfStatus = selfStatus
        self.answer = answer
        self.refuses = refuses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        let path = request.url.path
        if path.contains("/mole/world") {
            return ok(Data(LocalBridgeBackendTests.shell(app: "DynamiteWebUi").utf8))
        }
        if path.contains("/api/get_self_user_status") {
            var response = GetSelfUserStatusResponse()
            response.userStatus = selfStatus
            response.userStatus.userID.id = "u-me"
            return try ok(response.serializedBytes())
        }
        if let call = Self.calls.first(where: { path.contains("/api/\($0)") }) {
            if refuses {
                throw Refused()
            }
            return try ok(answerBody(for: call))
        }
        return ok(Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }

    /// Each answer carries a revision, so its body is never empty.
    private func answerBody(for call: String) throws -> Data {
        var revision = WriteRevision()
        revision.timestamp = 1
        switch call {
        case "set_custom_status":
            var response = SetCustomStatusResponse()
            response.userRevision = revision
            if let answer {
                response.userStatus = answer
            }
            return try response.serializedBytes()
        case "set_dnd_duration":
            var response = SetDndDurationResponse()
            response.userRevision = revision
            if let answer {
                response.userStatus = answer
            }
            return try response.serializedBytes()
        default:
            var response = SetPresenceSharedResponse()
            response.userRevision = revision
            if let answer {
                response.userStatus = answer
            }
            return try response.serializedBytes()
        }
    }

    private func ok(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }
}

/// Setting your status through the bridge (set-your-status spec §3).
@Suite(.timeLimit(.minutes(1)))
struct OwnStatusTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private let me = ChatKit.Member.ID("u-me")

    /// Your status and availability events only: the channel, which this
    /// transport never opens, keeps reporting its reconnects in between.
    private func own(_ events: [ChatEvent]) -> [ChatEvent] {
        events.filter { event in
            switch event {
            case .statusChanged, .availabilityChanged: true
            default: false
            }
        }
    }

    private func requests(_ transport: StatusTransport, _ call: String) async -> [HTTPRequest] {
        await transport.sent.filter { $0.url.path.contains("/api/\(call)") }
    }

    private func connected(_ transport: StatusTransport) async throws
        -> (LocalBridgeBackend, SenderEventLog) {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = await log.settle()
        return (backend, log)
    }

    @Test func theBackendAdvertisesSettingStatus() {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: StatusTransport())
        #expect(backend.capabilities.canSetStatus)
    }

    @Test func connectReportsYourAvailabilityAfterWhoYouAre() async throws {
        var away = UserStatus()
        away.presenceShared = false
        let (_, log) = try await connected(StatusTransport(selfStatus: away))
        let events = await log.settle()
        let identified = try #require(events.firstIndex {
            if case .selfIdentified = $0 {
                true
            } else {
                false
            }
        })
        let availability = try #require(events.firstIndex { $0 == .availabilityChanged(.away) })
        #expect(identified < availability)
    }

    @Test func aStatusIsSentAndItsAnswerComesBackForYou() async throws {
        var answer = UserStatus()
        answer.userID.id = "u-me"
        answer.customStatus.statusText = "Working remotely"
        answer.customStatus.emoji.unicode = "🏠"
        let transport = StatusTransport(answer: answer)
        let (backend, log) = try await connected(transport)
        let mark = await log.events.count
        let status = MemberStatus(emoji: "🏠", text: "Working remotely")

        try await backend.send(.setStatus(status))
        let events = await log.settle(since: mark)

        let request = try #require(await requests(transport, "set_custom_status").first)
        let decoded = try SetCustomStatusRequest(serializedBytes: request.body ?? Data())
        #expect(decoded.customStatus.statusText == "Working remotely")
        #expect(own(events) == [.statusChanged(member: me, status: status)])
        #expect(await backend.presencePoll.statuses[me] == status)
    }

    /// Review finding 1: an answer that leaves out your custom status says
    /// nothing about it, so the status just accepted is shown, and the poll
    /// remembers it, or a poll agreeing with the old value would never
    /// correct it. Your availability is not touched.
    @Test func aStatusAnswerWithoutTheStatusShowsWhatWasSet() async throws {
        let (backend, log) = try await connected(StatusTransport())
        let mark = await log.events.count
        let status = MemberStatus(emoji: "🏠", text: "Working remotely")

        try await backend.send(.setStatus(status))

        #expect(await own(log.settle(since: mark)) == [.statusChanged(member: me, status: status)])
        #expect(await backend.presencePoll.statuses[me] == status)
    }

    @Test func clearingIsShownAndForgotten() async throws {
        let (backend, log) = try await connected(StatusTransport())
        try await backend.send(.setStatus(MemberStatus(text: "Busy")))
        let mark = await log.settle().count

        try await backend.send(.setStatus(nil))

        #expect(await own(log.settle(since: mark)) == [.statusChanged(member: me, status: nil)])
        #expect(await backend.presencePoll.statuses[me] == nil)
    }

    /// Review finding 1: answers that carry neither Do not disturb nor
    /// presence sharing show what was asked for, once per call, and never
    /// touch your custom status.
    @Test func awayIsShownAndYourStatusIsLeftAlone() async throws {
        let (backend, log) = try await connected(StatusTransport())
        let mark = await log.events.count

        try await backend.send(.setAvailability(.away))

        #expect(await own(log.settle(since: mark)) == [
            .availabilityChanged(.away),
            .availabilityChanged(.away)
        ])
    }

    /// An answer that carries both parts is believed over the request.
    @Test func anAnswerThatSaysBothPartsIsBelieved() async throws {
        let serverEnd = Date(timeIntervalSince1970: 1_900_000_060)
        var answer = UserStatus()
        answer.dndSettings.dndState = .dnd
        answer.dndSettings.dndExpiryTimeUsec = 1_900_000_060_000_000
        answer.presenceShared = true
        let (backend, log) = try await connected(StatusTransport(answer: answer))
        let mark = await log.events.count

        try await backend
            .send(.setAvailability(.doNotDisturb(until: Date(timeIntervalSince1970: 1_900_000_000))))

        #expect(await own(log.settle(since: mark)) == [.availabilityChanged(.doNotDisturb(until: serverEnd))])
    }

    /// Away: presence not shared, then Do not disturb off, in that order.
    @Test func awaySendsPresenceThenDoNotDisturbOff() async throws {
        let transport = StatusTransport()
        let (backend, _) = try await connected(transport)
        try await backend.send(.setAvailability(.away))
        let sent = await transport.sent.map(\.url.path).filter { path in
            StatusTransport.calls.contains { path.contains("/api/\($0)") }
        }
        #expect(sent.count == 2)
        #expect(sent.first?.contains("/api/set_presence_shared") == true)
        #expect(sent.last?.contains("/api/set_dnd_duration") == true)
        let shared = try #require(await requests(transport, "set_presence_shared").first?.body)
        #expect(try SetPresenceSharedRequest(serializedBytes: shared).presenceShared == false)
    }

    @Test func doNotDisturbSendsOnlyItsEnd() async throws {
        let transport = StatusTransport()
        let (backend, _) = try await connected(transport)
        let end = Date(timeIntervalSince1970: 1_900_000_000)
        try await backend.send(.setAvailability(.doNotDisturb(until: end)))
        let dnd = try #require(await requests(transport, "set_dnd_duration").first?.body)
        #expect(try SetDndDurationRequest(serializedBytes: dnd).currentDndState == .dnd)
        #expect(await requests(transport, "set_presence_shared").isEmpty)
    }

    /// Any error will do: `SyncEngine.submit` records whatever is thrown.
    @Test func aRefusedCallThrows() async throws {
        let (backend, _) = try await connected(StatusTransport(refuses: true))
        await #expect(throws: (any Error).self) {
            try await backend.send(.setStatus(MemberStatus(text: "x")))
        }
    }

    @Test func aCommandBeforeConnectIsRefused() async throws {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: StatusTransport())
        await #expect(throws: (any Error).self) {
            try await backend.send(.setAvailability(.away))
        }
    }

    @Test func anAnswerWithoutAUserStatusEmitsNothing() async throws {
        let (backend, log) = try await connected(StatusTransport(answer: nil))
        let mark = await log.events.count
        try await backend.send(.setStatus(MemberStatus(text: "x")))
        let events = await log.settle(since: mark)
        #expect(!events.contains {
            if case .statusChanged = $0 {
                true
            } else {
                false
            }
        })
        #expect(!events.contains {
            if case .availabilityChanged = $0 {
                true
            } else {
                false
            }
        })
    }
}
