import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MeetingLinkJoinTests {
    @Test(arguments: [true, false])
    func previewReadsOnlyTheTitleForTheResolvedMeeting(_ matches: Bool) async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let input = try #require(URL(string: "https://meet.google.com/meet/abc-defg-hij?authuser=3"))
        let agenda = matches ? "https://meet.google.com/abc-defg-hij" : "https://meet.google.com/ooo-oooo-ooo"
        let setup = try await fixtures.setup(fixtures.nativeResponses(), agenda: Self.agenda(url: agenda))
        try await setup.service.startListening()
        let title = try await setup.service.previewMeetingTitle(at: input)
        #expect(title == (matches ? "Planning review" : nil))
        #expect(setup.service.conversationSnapshot == nil && setup.media.engines.isEmpty)
        let sent = await setup.base.sent
        let meetRPCs = sent.filter { $0.url.host == "meet.google.com" && $0.url.path.contains("/$rpc/") }
        #expect(meetRPCs.map(\.url.lastPathComponent) == ["ResolveMeetingSpace"])
        let resolve = try #require(meetRPCs.first)
        #expect(try resolve.body == MeetCallWire.resolveOffered(code: "abc-defg-hij"))
        let request = try #require(await setup.transport.agendaRequests.first)
        #expect(request.method == .post && request.body == Data() && !request.followsRedirects)
        #expect(request.headers["x-goog-meeting-token"] == "10;resolved")
        #expect(request.headers["x-goog-authuser"] == resolve.headers["x-goog-authuser"])
        await setup.service.stop()
    }

    @Test func agendaTitleArrivesWhileNativeMediaIsStillConnecting() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(
            fixtures.nativeResponses(), hold: "CreateMediaSession",
            agenda: Self.agenda(url: "https://meet.google.com/abc-defg-hij?authuser=3")
        )
        try await setup.service.startListening()
        let id = UUID(), url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let joining = Task { try await setup.service.joinMeeting(at: url, callID: id) }
        try await fixtures.waitForHold(setup)
        #expect(await eventually {
            setup.service.conversationSnapshot?.target.displayName == "Planning review"
        })
        #expect(setup.service.conversationSnapshot?.phase == .connecting)
        let request = try #require(await setup.transport.agendaRequests.first)
        let resolve = try #require(await setup.base.sent
            .first { $0.url.path.hasSuffix("/ResolveMeetingSpace") })
        #expect(request.method == .post && request.body == Data() && !request.followsRedirects)
        #expect(request.headers["x-goog-meeting-token"] == "10;resolved")
        #expect(request.headers["x-goog-authuser"] == resolve.headers["x-goog-authuser"])
        await setup.transport.release()
        try await joining.value
        #expect(setup.service.conversationSnapshot?.target.displayName == "Planning review")
        try await setup.service.hangUp(callID: id)
        await setup.service.stop()
    }

    @Test func joinedMeetingKeepsDialInWhenActivitiesRefresh() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        var responses = fixtures.nativeResponses()
        let region: String? = (Locale.current.region?.identifier).flatMap { code in
            code.utf8.count == 2 && code.utf8.allSatisfy { (65 ... 90).contains($0) } ? code : nil
        }
        let dialIn = CallDialIn(phoneNumber: "+1 202-555-0142", pin: "012345678", regionCode: region)
        let alternate = CallDialIn(phoneNumber: "+44 20 7946 0958", pin: "987654321")
        var row = NativeMeetFixture.string(2, dialIn.pin) + NativeMeetFixture.string(5, dialIn.phoneNumber)
        if let region {
            row += NativeMeetFixture.string(3, region)
        }
        let alternateRow = NativeMeetFixture.string(2, alternate.pin)
            + NativeMeetFixture.string(5, alternate.phoneNumber)
        let rows = (region == nil ? [row, alternateRow] : [alternateRow, row])
            .reduce(Data()) { $0 + NativeMeetFixture.bytes(5, $1) }
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let directory = try #require(URL(string: "https://tel.meet/abc-defg-hij?hs=5"))
        let space = NativeMeetFixture.string(1, "spaces/demo")
            + NativeMeetFixture.string(2, "abc-defg-hij") + NativeMeetFixture.string(3, url.absoluteString)
            + rows
            + NativeMeetFixture.bytes(8, NativeMeetFixture.string(1, dialIn.pin))
        responses[1] = NativeMeetFixture.ok(space, token: "10;resolved")
        let setup = try await fixtures.setup(responses)
        try await setup.service.startListening()
        let id = UUID()
        try await setup.service.joinMeeting(at: url, callID: id)
        try await setup.service.hangUp(callID: id)

        let seen = await interactions(setup, callID: id)
        #expect(seen.first?.activities == nil)
        #expect(seen.contains { $0.activities != nil })
        #expect(seen.allSatisfy {
            $0.joinURL == url && $0.dialIn == dialIn && $0.alternateDialIns == [alternate]
                && $0.dialInNumbersURL == directory
        })
        await setup.service.stop()
    }

    @Test(arguments: [200, 403])
    func refusedOrForeignAgendaKeepsTheGenericTitleAndCannotGateAdmission(_ status: Int) async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(
            fixtures.nativeResponses(), hold: "FetchCalendarEvent",
            agenda: Self.agenda(url: "https://meet.google.com/zzz-zzzz-zzz", status: status)
        )
        try await setup.service.startListening()
        let id = UUID(), url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        try await setup.service.joinMeeting(at: url, callID: id)
        try await fixtures.waitForHold(setup)
        #expect(setup.media.engines.count == 1)
        #expect(setup.service.conversationSnapshot?.target.displayName == "Meeting")
        let pending = setup.service.meetingAgendaRead
        await setup.transport.release()
        await pending?.value
        #expect(setup.service.conversationSnapshot?.target.displayName == "Meeting")
        try await setup.service.hangUp(callID: id)
        await setup.service.stop()
    }

    @Test func aLateAgendaCannotRenameAnEndedCall() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(
            fixtures.nativeResponses(), hold: "FetchCalendarEvent",
            agenda: Self.agenda(url: "https://meet.google.com/abc-defg-hij")
        )
        try await setup.service.startListening()
        let id = UUID(), url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        try await setup.service.joinMeeting(at: url, callID: id)
        try await fixtures.waitForHold(setup)
        let pending = try #require(setup.service.meetingAgendaRead)
        try await setup.service.hangUp(callID: id)
        #expect(pending.isCancelled)
        await setup.transport.release()
        await pending.value
        #expect(setup.service.conversationSnapshot?.phase == .ended)
        #expect(setup.service.conversationSnapshot?.target.displayName == "Meeting")
        await setup.service.stop()
    }

    private static func agenda(url: String?, status: Int = 200, rows: [Data] = []) -> HTTPResponse {
        var event = NativeMeetFixture.string(5, "Planning review")
        if let url {
            event += NativeMeetFixture.string(17, url)
        }
        for row in rows {
            event += NativeMeetFixture.bytes(19, row)
        }
        let body = NativeMeetFixture.bytes(1, event) + NativeMeetFixture.string(2, "private-agenda-topic")
        return HTTPResponse(status: status, headers: HTTPHeaders([]), body: body.base64EncodedData())
    }

    @Test(arguments: ["", "?authuser=2&utm_source=calendar&companion=1"])
    func joiningDuringAccountBootstrapWaitsAndUsesTheExistingMeetingWithoutInviting(
        _ query: String
    ) async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(fixtures.nativeResponses(), hold: "*")
        let listening = Task { try await setup.service.startListening() }
        try await fixtures.waitForHold(setup)
        let id = UUID(), url = try #require(URL(string:
            "https://meet.google.com/meet/abc-defg-hij" + query
        ))
        let canonicalURL = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let joining = Task { try await setup.service.joinMeeting(at: url, callID: id) }
        #expect(await eventually { setup.service.conversationSnapshot?.id == id })
        #expect(setup.media.engines.isEmpty)
        await setup.transport.release()
        try await listening.value
        try await joining.value
        #expect(setup.media.engines.count == 1)
        #expect(setup.service.conversationSnapshot?.target.meetingURL == canonicalURL)
        let sent = await setup.base.sent
        let resolve = try #require(sent.first { $0.url.path.hasSuffix("ResolveMeetingSpace") })
        #expect(try resolve.body == (MeetCallWire.resolveOffered(code: "abc-defg-hij")))
        #expect(try resolve
            .headers["X-Goog-Meeting-Identifier"] == (MeetCallWire.offeredIdentifier(code: "abc-defg-hij")))
        #expect(!sent.contains { $0.url.path.hasSuffix("ResolveForHangoutsChat") })
        #expect(!sent.contains { $0.url.path.hasSuffix("CreateMeetingInvite") })
        try await setup.service.hangUp(callID: id)
        await setup.service.stop()
    }

    @Test(arguments: [true, false])
    func endingAJoinDuringBootstrapDoesNotCancelTheSharedAccountSetup(_ meetingLink: Bool) async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(fixtures.nativeResponses(), hold: "*")
        let listening = Task { try await setup.service.startListening() }
        try await fixtures.waitForHold(setup)
        let id = UUID(), url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let joining = Task {
            if meetingLink {
                try await setup.service.joinMeeting(at: url, callID: id)
            } else {
                try await setup.service.joinConversationCall(to: .init(
                    conversationID: .init("space/test-group"), displayName: "Group"
                ), callID: id)
            }
        }
        #expect(await eventually { setup.service.conversationSnapshot?.id == id })
        try await setup.service.hangUp(callID: id)
        await #expect(throws: CancellationError.self) { try await joining.value }
        #expect(setup.service.conversationSnapshot?.phase == .ended)
        #expect(setup.media.engines.isEmpty && !setup.service.hasLoadedPeople)
        await setup.transport.release()
        try await listening.value
        #expect(setup.service.hasLoadedPeople)
        #expect(await setup.base.sent.allSatisfy { !$0.url.path.hasSuffix("ResolveMeetingSpace") })
        await setup.service.stop()
    }

    @Test func resolverRefusalRemainsInTheMatchingMeetingReportWithoutLeakingTheLink() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let refused = HTTPResponse(
            status: 403,
            headers: HTTPHeaders([]),
            body: Data("private-provider-url-and-token".utf8)
        )
        let setup = try await fixtures.setup([fixtures.nativeResponses()[0], .success(refused)])
        try await setup.service.startListening()
        let id = UUID(), url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        await #expect(throws: ChatError.self) { try await setup.service.joinMeeting(at: url, callID: id) }
        let report = try #require(await setup.service.diagnosticReport(callID: id))
        #expect(report.contains("ResolveMeetingSpace: public meeting link started"))
        #expect(report.contains("Meeting link preparation: HTTP 403"))
        #expect(!report.contains("abc-defg-hij") && !report.contains("private-provider-url-and-token"))
        #expect(setup.media.engines.isEmpty)
        #expect(await setup.service.diagnosticReport(callID: UUID()) == nil)
        await setup.service.stop()
        #expect(await setup.service.diagnosticReport(callID: id) == nil)
    }

    @Test(arguments: [UInt64(3), 13])
    func joinReturnsWhilePendingAndHangupWithdrawsTheSameRegistration(_ state: UInt64) async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(waitingResponses(state, fixtures: fixtures))
        try await setup.service.startListening()
        let id = UUID(), url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        try await setup.service.joinMeeting(at: url, callID: id)
        #expect(setup.service.operation != nil)
        #expect(setup.service.conversationSnapshot?.phase == .connecting)
        #expect(setup.service.conversationSnapshot?
            .admission == (state == 3 ? .requestPending : .waitingRoom))
        #expect(setup.media.engines.first?.isMicrophoneMuted == true)
        #expect(setup.media.engines.first?.requests.isEmpty == true)
        try await setup.service.hangUp(callID: id)
        #expect(setup.service.operation == nil)
        #expect(setup.service.conversationSnapshot?.phase == .ended)
        #expect(setup.service.conversationSnapshot?.admission == nil)
        let writes = await setup.base.sent.filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
        #expect(writes.count == 2)
        #expect(writes.last?.headers["x-goog-meeting-token"] == "30;pending")
        #expect(try writes.last?.body == (MeetDeviceWire.leave(device: "spaces/demo/devices/one")))
        await setup.service.stop()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }
}

extension MeetingLinkJoinTests {
    @Test func laterAdmissionFinishesNativeSetupOnTheSameCall() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        var responses = waitingResponses(13, fixtures: fixtures)
        let joined = NativeMeetGuestAdmissionTests.collection(1, [NativeMeetGuestAdmissionTests.device(1)])
        responses.insert(contentsOf: [joined, joined], at: responses.count - 1)
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let setup = try await fixtures.setup(
            responses,
            agenda: Self.agenda(url: url.absoluteString, rows: Self.waitingRoomAgendaRows),
            holdAgendaToken: "30;pending"
        )
        try await setup.service.startListening()
        let id = UUID()
        try await setup.service.joinMeeting(at: url, callID: id)
        #expect(setup.service.conversationSnapshot?.admission == .waitingRoom)
        try await fixtures.waitForHold(setup)
        let pendingAgenda = try #require(setup.service.waitingRoomAgendaRead)
        let deadline = ContinuousClock.now + .seconds(12)
        while setup.service.conversationSnapshot?.phase == .connecting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(setup.service.conversationSnapshot?.id == id)
        #expect(setup.service.conversationSnapshot?.phase == .connected)
        #expect(setup.service.conversationSnapshot?.admission == nil)
        #expect(setup.media.engines.first?.isMicrophoneMuted == false)
        #expect(setup.media.engines.first?.requests.count == 1)
        #expect(pendingAgenda.isCancelled)
        await setup.transport.release()
        await pendingAgenda.value
        #expect(await eventually { setup.service.operation == nil })
        try await setup.service.hangUp(callID: id)
        let seen = await interactions(setup, callID: id)
        #expect(!seen.isEmpty && seen.allSatisfy(\.canInvite))
        let writes = await setup.base.sent.filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
        #expect(writes.count == 2)
        await setup.service.stop()
    }

    @Test(arguments: [UInt64(3), 13], [true, false, nil] as [Bool?])
    func waitingRoomProjectsOnlyOrdinaryAttachmentsFromTheExactAgenda(
        _ state: UInt64,
        _ matches: Bool?
    ) async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let agendaURL = matches.map { $0 ? url.absoluteString : "https://meet.google.com/ooo-oooo-ooo" }
        let setup = try await fixtures.setup(waitingResponses(state, fixtures: fixtures), agenda: Self.agenda(
            url: agendaURL, rows: Self.waitingRoomAgendaRows
        ))
        try await setup.service.startListening()
        let id = UUID()
        try await setup.service.joinMeeting(at: url, callID: id)
        await setup.service.waitingRoomAgendaRead?.value
        let request = await setup.transport.agendaRequests
            .first { $0.headers["x-goog-meeting-token"] == "30;pending" }
        if state == 13 {
            let waitingRead = try #require(request)
            #expect(waitingRead.method == .post && waitingRead.body == Data() && !waitingRead
                .followsRedirects)
        } else {
            #expect(request == nil)
        }
        #expect(setup.media.engines.first?.isMicrophoneMuted == true)
        try await setup.service.hangUp(callID: id)
        let seen = await interactions(setup, callID: id)
        if state == 13, matches == true {
            let state = try #require(seen.first)
            #expect(seen.count == 1 && state.joinURL == url && !state.canInvite && !state.canRaiseHand)
            #expect(state.activities?.agendaAttachments?.map(\.title) == ["Planning document"])
            #expect(state.activities?.artifactFiles.isEmpty == true && state.activities?.agendaGuests == nil)
        } else {
            #expect(seen.isEmpty)
        }
        await setup.service.stop()
    }

    @Test func heldWaitingRoomAgendaCannotPublishAfterCancelJoin() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let setup = try await fixtures.setup(
            waitingResponses(13, fixtures: fixtures),
            agenda: Self.agenda(url: url.absoluteString, rows: Self.waitingRoomAgendaRows),
            holdAgendaToken: "30;pending"
        )
        try await setup.service.startListening()
        let id = UUID()
        try await setup.service.joinMeeting(at: url, callID: id)
        try await fixtures.waitForHold(setup)
        let read = try #require(setup.service.waitingRoomAgendaRead)
        try await setup.service.hangUp(callID: id)
        #expect(read.isCancelled)
        await setup.transport.release()
        await read.value
        #expect(await interactions(setup, callID: id).isEmpty)
        #expect(setup.service.waitingRoomAgendaRead == nil)
        await setup.service.stop()
    }

    private func waitingResponses(_ state: UInt64, fixtures: LocalBridgeAudioCallServiceTests)
        -> [Result<HTTPResponse, any Error>] {
        var responses = fixtures.nativeResponses()
        responses[responses.count - 2] = NativeMeetFixture.ok(
            NativeMeetGuestAdmissionTests.device(state), token: "30;pending"
        )
        return responses
    }

    private static let waitingRoomAgendaRows = [
        NativeMeetFixture.string(1, "https://docs.google.com/document/d/synthetic-planning/edit")
            + NativeMeetFixture.string(2, "Planning document") + NativeMeetFixture.number(6, 1),
        NativeMeetFixture.string(1, "https://drive.google.com/file/d/synthetic-recording/view")
            + NativeMeetFixture.number(6, 3) + NativeMeetFixture.number(7, 1)
    ]

    private func interactions(_ setup: LocalBridgeAudioCallServiceTests.Setup, callID: UUID) async
        -> [CallInteractionState] {
        var interactions: [CallInteractionState] = []
        for await event in setup.service.events {
            if case let .meetingSnapshot(call) = event, call.id == callID, call.phase.isTerminal {
                break
            }
            if case let .interactionChanged(id, state) = event, id == callID,
               let state {
                interactions.append(state)
            }
        }
        return interactions
    }
}
