import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Routes by host and path: the shell for `connect()`, `/app/home`,
/// `get_membership`, and the people search. Everything else answers an empty
/// 200. Duplicated rather than shared, as this suite's other transports are.
private actor PeopleTransport: HTTPTransport {
    struct NoStream: Error {}
    private let shell: HTTPResponse
    private let appHome: HTTPResponse
    private let people: HTTPResponse
    private let membership: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(shell: HTTPResponse, appHome: HTTPResponse, people: HTTPResponse, membership: HTTPResponse) {
        self.shell = shell
        self.appHome = appHome
        self.people = people
        self.membership = membership
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.host == "people-pa.clients6.google.com" {
            return people
        }
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.hasSuffix("/app/home") {
            return appHome
        }
        if request.url.path.contains("/api/get_membership") {
            return membership
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// The directory search and the membership check (mention non-members spec
/// §3.3). Every cookie value and person here is invented.
@Suite(.timeLimit(.minutes(1)))
struct PeopleSearchTests {
    private static let cookies = SessionCookies(cookies: [
        SessionCookies.Cookie(name: "SID", value: "a", domain: ".google.com", path: "/"),
        SessionCookies.Cookie(name: "SAPISID", value: "sap-1", domain: ".google.com", path: "/")
    ])!

    static let answer = #"""
    [[["one@example.invalid",null,"PERSON",["123456789012345678901",[null],\#
    [[[null],"One Person",null,"One"]],[[[null],"https://example.invalid/one.png"]]]],\#
    ["group@example.invalid",null,"GOOGLE_GROUP",null,["987654321098765432109"]]]]
    """#

    private static func ok(_ body: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(body.utf8))
    }

    /// The shell, with the Punctual key when `key` is given.
    private static func shell(key: String?) -> HTTPResponse {
        let extra = key.map { #","Tzliq":"\#($0)""# } ?? ""
        return ok("""
        <script nonce="x">window.WIZ_global_data = ({"qwAQke":"DynamiteWebUi",\
        "SMqcke":"\(String(repeating: "t", count: 42))","cfb2h":"boq_x"\(extra)});</script>
        """)
    }

    private static func membershipAnswer(_ state: MembershipState?) throws -> HTTPResponse {
        var response = GetMembershipResponse()
        if let state {
            var row = Membership()
            row.membershipState = state
            response.memberships = [row]
        } else {
            // No membership, but not zero bytes either (an empty body is an
            // error before it is an answer): field 1, varint 1, a field this
            // message does not name.
            try response.merge(serializedBytes: Data([0x08, 0x01]))
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private static func connected(
        shellKey: String? = "key-1",
        appHomeKey: String? = nil,
        membership: MembershipState? = .memberJoined
    ) async throws -> (LocalBridgeBackend, PeopleTransport) {
        let appHome = appHomeKey.map { shell(key: $0) } ?? ok("<html></html>")
        let transport = try PeopleTransport(
            shell: shell(key: shellKey), appHome: appHome, people: ok(answer),
            membership: membershipAnswer(membership)
        )
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        try await backend.connect()
        return (backend, transport)
    }

    private static func peopleRequests(_ transport: PeopleTransport) async -> [HTTPRequest] {
        await transport.sent.filter { $0.url.host == "people-pa.clients6.google.com" }
    }

    @Test func aSearchSendsTheKeyAndASAPISIDHashAlone() async throws {
        let (backend, transport) = try await Self.connected()
        _ = try await backend.searchPeople("on")
        let request = try #require(await Self.peopleRequests(transport).first)
        #expect(request.headers.all("X-Goog-Api-Key") == ["key-1"])
        let authorization = try #require(request.headers.all("Authorization").first)
        #expect(authorization
            .range(of: #"^SAPISIDHASH \d+_[0-9a-f]{40}$"#, options: .regularExpression) != nil)
    }

    @Test func peopleBecomeHumanMembers() async throws {
        let (backend, _) = try await Self.connected()
        let people = try await backend.searchPeople("on")
        #expect(people == [ChatKit.Member(
            id: ChatKit.Member.ID("123456789012345678901"), kind: .human, displayName: "One Person",
            email: "one@example.invalid", avatarURL: URL(string: "https://example.invalid/one.png")
        )])
    }

    @Test func withoutAKeyInTheShellAppHomeIsFetchedOnce() async throws {
        let (backend, transport) = try await Self.connected(shellKey: nil, appHomeKey: "key-2")
        _ = try await backend.searchPeople("o")
        _ = try await backend.searchPeople("on")
        let homes = await transport.sent.filter { $0.url.path.hasSuffix("/app/home") }
        #expect(homes.count == 1)
        #expect(await Self.peopleRequests(transport).last?.headers.all("X-Goog-Api-Key") == ["key-2"])
    }

    @Test func noKeyAnywhereThrowsAndReportsOnce() async throws {
        let (backend, _) = try await Self.connected(shellKey: nil, appHomeKey: nil)
        let reports = Reports()
        // One reader for the whole test, bounded in time: cancelling it ends
        // the stream, which this test no longer needs (CLAUDE.md).
        let reader = Task {
            for await event in backend.events {
                if case let .backendError(error) = event, String(describing: error).contains("Tzliq") {
                    await reports.add()
                }
            }
        }
        await #expect(throws: (any Error).self) { _ = try await backend.searchPeople("o") }
        await #expect(throws: (any Error).self) { _ = try await backend.searchPeople("on") }
        try await Task.sleep(for: .milliseconds(200))
        reader.cancel()
        #expect(await reports.count == 1)
    }

    private actor Reports {
        private(set) var count = 0

        func add() {
            count += 1
        }
    }

    // MARK: - Membership

    @Test func aJoinedMemberIsAMember() async throws {
        let (backend, _) = try await Self.connected(membership: .memberJoined)
        #expect(try await backend
            .membership(of: ChatKit.Member.ID("u-1"), in: Conversation.ID("space/s-1")) == .member)
    }

    @Test func notAMemberIsNotAMember() async throws {
        let (backend, _) = try await Self.connected(membership: .memberNotAMember)
        #expect(try await backend.membership(of: ChatKit.Member.ID("u-1"), in: Conversation.ID("space/s-1"))
            == .notMember)
    }

    @Test func anEmptyAnswerIsUnknown() async throws {
        let (backend, _) = try await Self.connected(membership: nil)
        #expect(try await backend.membership(of: ChatKit.Member.ID("u-1"), in: Conversation.ID("space/s-1"))
            == .unknown)
    }

    @Test func aDirectMessageIsUnknownAndAsksNothing() async throws {
        let (backend, transport) = try await Self.connected()
        #expect(try await backend
            .membership(of: ChatKit.Member.ID("u-1"), in: Conversation.ID("dm/d-1")) == .unknown)
        #expect(await transport.sent.allSatisfy { !$0.url.path.contains("get_membership") })
    }
}
