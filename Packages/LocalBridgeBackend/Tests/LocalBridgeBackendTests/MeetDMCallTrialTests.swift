import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MeetDMCallTrialTests {
    private actor LoadingProgress {
        private(set) var steps: [MeetDMCallLoadStep] = []
        private(set) var reports: [String] = []

        func record(_ step: MeetDMCallLoadStep, report: String) {
            steps.append(step)
            reports.append(report)
        }
    }

    private final class Storage: SecretStorage, @unchecked Sendable {
        var items: [String: Data] = [:]
        func read(account: String) throws -> Data? {
            items[account]
        }

        func write(_ data: Data, account: String) throws {
            items[account] = data
        }

        func delete(account: String) throws {
            items[account] = nil
        }
    }

    private actor HoldInvite: HTTPTransport {
        let base: ScriptedTransport
        private(set) var started = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ base: ScriptedTransport) {
            self.base = base
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let response = try await base.send(request)
            if request.url.path.hasSuffix("CreateMeetingInvite") {
                started = true
                if !released {
                    await withCheckedContinuation { continuation = $0 }
                }
            }
            return response
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStream {
            try await base.stream(request)
        }
    }

    private func session(at capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> StoredSession {
        StoredSession(credential: SessionCookies(cookies: [
            .init(name: "SAPISID", value: "cookie-sentinel", domain: ".google.com", path: "/"),
            .init(name: "MOSID", value: "meet-sentinel", domain: "meet.google.com", path: "/")
        ])!, capturedAt: capturedAt, expiresAt: nil)
    }

    func trial(
        _ transport: any HTTPTransport
    ) async throws -> (MeetDMCallTrial, KeychainCredentialStore) {
        let store = KeychainCredentialStore(storage: Storage(), account: "trial-test")
        try await store.store(session())
        return (MeetDMCallTrial(store: store, transport: transport), store)
    }

    private func ok(_ body: Data, headers: [(String, String)] = []) -> Result<HTTPResponse, any Error> {
        .success(HTTPResponse(status: 200, headers: HTTPHeaders(headers), body: body))
    }

    func loadingResponses(
        memberCountEstimate: Int32? = nil
    ) throws -> [Result<HTTPResponse, any Error>] {
        var selfStatus = GetSelfUserStatusResponse()
        selfStatus.userStatus.userID.id = "self"
        var world = PaginatedWorldResponse()
        world.worldItems = [
            dm("valid-dm", ["self", "alice-id"]),
            dm("bot-dm", ["self", "bot-id"]),
            dm("self-dm", ["self", "self"]),
            dm("foreign-dm", ["other", "alice-id"]),
            WorldItemFixture.item(
                groupID: WorldItemFixture.spaceGroupID("group-id"),
                dmMembers: ["self", "alice-id", "other"], groupType: .immutableMembershipGroupDm
            )
        ]
        if let memberCountEstimate {
            var segment = SegmentedMembershipCount()
            segment.membershipCount = memberCountEstimate
            segment.memberType = .humanUser
            segment.membershipState = .memberJoined
            world.worldItems[0].segmentedMembershipCounts.value = [segment]
        }
        var members = GetMembersResponse()
        members.members = [member("alice-id", name: "Alice Person"), member("bot-id", name: "Bot", bot: true)]
        return try [
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")),
            ok(selfStatus.serializedBytes()), ok(world.serializedBytes()), ok(members.serializedBytes())
        ]
    }

    private func dm(_ id: String, _ members: [String]) -> WorldItemLite {
        WorldItemFixture.item(
            groupID: WorldItemFixture.dmGroupID(id), dmMembers: members, groupType: .oneToOneHumanDm
        )
    }

    private func member(_ id: String, name: String, bot: Bool = false) -> GChatBridgeCore.Member {
        var member = GChatBridgeCore.Member()
        member.user.userID.id = id
        member.user.userID.type = bot ? .bot : .human
        member.user.name = name
        member.user.email = "\(id)@example.test"
        return member
    }

    func preparingResponses() -> [Result<HTTPResponse, any Error>] {
        let key = "AIza" + String(repeating: "K", count: 35)
        return [
            ScriptedTransport.ok("<script>window.WIZ_global_data={};</script>\(key) \(key)"),
            resolvedResponse(token: "prepared-token")
        ]
    }

    private func resolvedResponse(
        token: String = "after-join-token", spaceName: String = "spaces/abc"
    ) -> Result<HTTPResponse, any Error> {
        let body = Data([0x0A, UInt8(spaceName.utf8.count)]) + Data(spaceName.utf8)
            + Data([0x12, 0x0C]) + Data("abc-defg-hij".utf8)
            + Data([0x1A, 0x24]) + Data("https://meet.google.com/abc-defg-hij".utf8)
        return ok(Data(body.base64EncodedString().utf8), headers: [("x-goog-meeting-token", token)])
    }

    private func inviteResponse() -> Result<HTTPResponse, any Error> {
        ok(Data(Data([0x0A, 0x01, 0x31]).base64EncodedString().utf8))
    }
}

extension MeetDMCallTrialTests {
    @Test func loadingListsOnlyNamedHumanOneToOneRecipientsAndSendsNoMeetRequest() async throws {
        let transport = try ScriptedTransport(loadingResponses())
        let (trial, _) = try await trial(transport)
        let people = try await trial.loadPeople()
        #expect(people.map(\.name) == ["Alice Person"])
        #expect(await transport.sent.count == 4)
        #expect(await transport.sent.allSatisfy { $0.url.host == "chat.google.com" })
    }

    /// Synthetic conflicting estimates: field 30's summed count is still an
    /// inference. The explicit DM kind, owner/peer pair and human profile are
    /// the evidence used to choose a one-to-one recipient.
    @Test(arguments: [Int32(1), Int32(3)])
    func humanDMPairDoesNotDependOnTheInferredMemberCount(_ estimate: Int32) async throws {
        let transport = try ScriptedTransport(loadingResponses(memberCountEstimate: estimate))
        let (trial, _) = try await trial(transport)
        let people = try await trial.loadPeople()
        #expect(people.map(\.name) == ["Alice Person"])
        #expect(await transport.sent.count == 4)
    }

    @Test func loadingReportsEachStepAndExplainsExcludedRecipientsWithoutIdentities() async throws {
        let transport = try ScriptedTransport(loadingResponses())
        let (trial, _) = try await trial(transport)
        let progress = LoadingProgress()
        _ = try await trial.loadPeople { step in
            await progress.record(step, report: trial.report)
        }
        #expect(await progress.steps == [
            .storedSession, .chatBootstrap, .selfAccount, .conversations, .profiles, .ready
        ])
        let reports = await progress.reports
        #expect(reports[3].contains("get_self_user_status: accepted"))
        #expect(!reports[3].contains("paginated_world: accepted"))
        #expect(reports[4].contains("3 with two listed members; 2 including current account"))
        #expect(reports[5].contains("Recipient profiles: 2 matched; 1 human; 1 named"))
        for secret in ["alice-id", "Alice Person", "@example.test", "cookie-sentinel"] {
            #expect(reports.allSatisfy { !$0.contains(secret) })
        }
    }

    @Test func failedWorldRequestKeepsTheWaitingStepAndSafeFailureInTheReport() async throws {
        let transport = try ScriptedTransport(
            Array(loadingResponses().prefix(2))
                + [.success(HTTPResponse(
                    status: 403, headers: HTTPHeaders([]), body: Data("secret-server-message".utf8)
                ))]
        )
        let (trial, _) = try await trial(transport)
        let progress = LoadingProgress()
        await #expect(throws: APIFailure.httpStatus(403)) {
            try await trial.loadPeople { step in
                await progress.record(step, report: trial.report)
            }
        }
        #expect(await progress.steps.last == .conversations)
        #expect(await progress.reports.last?.contains("Loading step: Loading your DM conversations…") == true)
        let report = await trial.report
        #expect(report.contains("403"))
        #expect(!report.contains("secret-server-message"))
        #expect(await transport.sent.count == 3)
    }

    @Test func ringingRequiresReportedBrowserJoinAndUsesTheRefreshedTokenForTheSelectedPerson() async throws {
        let transport = try ScriptedTransport(
            loadingResponses() + preparingResponses() + [resolvedResponse(), inviteResponse()]
        )
        let (trial, _) = try await trial(transport)
        let person = try #require(try await trial.loadPeople().first)
        let prepared = try await trial.prepare(person: person.id)
        #expect(prepared.url.absoluteString == "https://meet.google.com/abc-defg-hij")
        let beforeRing = await transport.sent
        #expect(beforeRing.count == 6)
        #expect(beforeRing.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })

        await #expect(throws: MeetDMCallTrialError.browserJoinRequired) {
            try await trial.ring(preparedID: prepared.id)
        }
        #expect(await transport.sent.count == 6)
        let joined = try await trial.prepareRingAfterBrowserJoin(preparedID: prepared.id)
        #expect(joined.id != prepared.id)
        #expect(joined.url == prepared.url)
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
        try await trial.ring(preparedID: joined.id)
        let sent = await transport.sent
        #expect(sent.count == 8)
        let invite = try #require(sent.last)
        #expect(invite.url.path.hasSuffix("CreateMeetingInvite"))
        #expect(invite.headers["x-goog-meeting-token"] == "after-join-token")
        let body = try #require(invite.body)
        let callee = try #require(ProtoFieldScan.payloads(ofField: 2, in: body).first)
        let calleeID = try #require(ProtoFieldScan.payloads(ofField: 2, in: callee).first)
        #expect(String(data: calleeID, encoding: .utf8) == "alice-id")
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: joined.id)
        }
        #expect(await transport.sent.count == 8)
        let report = await trial.report
        #expect(report.contains("CreateMeetingInvite: accepted after reported browser join"))
        for secret in [
            "alice-id",
            "Alice Person",
            "@example.test",
            "prepared-token",
            "after-join-token",
            "spaces/abc",
            "cookie-sentinel"
        ] {
            #expect(!report.contains(secret))
        }
    }

    @Test func accountReplacementPreventsRingingAndOldRotationCannotReplaceTheNewSession() async throws {
        let transport =
            try ScriptedTransport(loadingResponses() + preparingResponses() + [resolvedResponse()])
        let (trial, store) = try await trial(transport)
        let person = try #require(try await trial.loadPeople().first)
        let prepared = try await trial.prepare(person: person.id)
        let joined = try await trial.prepareRingAfterBrowserJoin(preparedID: prepared.id)
        let capture = try #require(try await store.snapshot())
        let replacement = session(at: Date(timeIntervalSince1970: 1_700_000_001))
        try await store.store(replacement)
        await #expect(throws: MeetDMCallTrialError.accountChanged) {
            try await trial.ring(preparedID: joined.id)
        }
        let stale = try #require(SessionCookies(header: "SID=stale"))
        try await store.replaceCredential(with: stale, belongingTo: capture)
        #expect(try await store.currentSession() == replacement)
        #expect(await transport.sent.count == 7)
    }

    @Test func refreshingAChangedSpaceInvalidatesTheTicketAndCannotInvite() async throws {
        let transport = try ScriptedTransport(
            loadingResponses() + preparingResponses() + [resolvedResponse(spaceName: "spaces/changed")]
        )
        let (trial, _) = try await trial(transport)
        let person = try #require(try await trial.loadPeople().first)
        let prepared = try await trial.prepare(person: person.id)
        await #expect(throws: MeetDMCallTrialError.callChanged) {
            try await trial.prepareRingAfterBrowserJoin(preparedID: prepared.id)
        }
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: prepared.id)
        }
        #expect(await transport.sent.count == 7)
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
    }

    @Test func anInternalInviteErrorCannotAutomaticallyRetry() async throws {
        let refusal = Data([0x08, 0x0D])
        let transport = try ScriptedTransport(
            loadingResponses() + preparingResponses() + [
                resolvedResponse(),
                .success(HTTPResponse(
                    status: 500, headers: HTTPHeaders([]),
                    body: refusal
                ))
            ]
        )
        let (trial, _) = try await trial(transport)
        let person = try #require(try await trial.loadPeople().first)
        let prepared = try await trial.prepare(person: person.id)
        let joined = try await trial.prepareRingAfterBrowserJoin(preparedID: prepared.id)
        await #expect(throws: MeetCallClientError.httpStatus(500, refusal: MeetCallRefusal(body: refusal))) {
            try await trial.ring(preparedID: joined.id)
        }
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: joined.id)
        }
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("CreateMeetingInvite") }.count == 1)
    }

    @Test func aNewPreparationInvalidatesThePreviousTicketEvenWhenTheNewPersonIsInvalid() async throws {
        let transport = try ScriptedTransport(loadingResponses() + preparingResponses())
        let (trial, _) = try await trial(transport)
        let person = try #require(try await trial.loadPeople().first)
        let prepared = try await trial.prepare(person: person.id)
        await #expect(throws: MeetDMCallTrialError.invalidPerson) {
            try await trial.prepare(person: UUID())
        }
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: prepared.id)
        }
        #expect(await transport.sent.count == 6)
    }

    @Test func aSecondRingWhileTheFirstResponseIsPendingCannotSendAnotherInvite() async throws {
        let base = try ScriptedTransport(
            loadingResponses() + preparingResponses() + [resolvedResponse(), inviteResponse()]
        )
        let transport = HoldInvite(base)
        let (trial, _) = try await trial(transport)
        let person = try #require(try await trial.loadPeople().first)
        let prepared = try await trial.prepare(person: person.id)
        let joined = try await trial.prepareRingAfterBrowserJoin(preparedID: prepared.id)
        let first = Task { try await trial.ring(preparedID: joined.id) }
        defer { Task { await transport.release() } }
        for _ in 0 ..< 1000 {
            if await transport.started {
                break
            }
            await Task.yield()
        }
        try #require(await transport.started)
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: joined.id)
        }
        await transport.release()
        try await first.value
        #expect(await base.sent.filter { $0.url.path.hasSuffix("CreateMeetingInvite") }.count == 1)
    }
}
