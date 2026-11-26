import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetAgendaArtifactsTests {
    @Test func guestInvitationsFollowTheAuthenticatedJoinedRoster() async throws {
        let transport = HeldAgendaArtifactsTransport()
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        let local = "spaces/demo/devices/one"
        try await session.reconcileParticipants(roster(1), local: local)
        await session.setActivitiesHandler { _ in }
        while await !transport.started {
            await Task.yield()
        }
        let read = try #require(await session.agendaArtifactRead)
        await transport.release()
        await read.value
        let guest = try #require(await session.activities.agendaGuests?.first)
        #expect(guest.displayName == "Taylor" && guest.response == "accepted")
        try await session.reconcileParticipants(roster(2, guestState: 3), local: local)
        #expect(await session.activities.agendaGuests == nil)
        try await session.reconcileParticipants(roster(3, guestState: 1), local: local)
        #expect(await session.activities.agendaGuests == nil)
        try await session.reconcileParticipants(roster(4), local: local)
        #expect(await session.activities.agendaGuests == [guest])
        await session.publishParticipantsUnavailable()
        await session.publishParticipants()
        await session.publishAgendaGuests()
        #expect(await session.activities.agendaGuests == nil)
        try await session.reconcileParticipants(roster(5), local: local)
        #expect(await session.activities.agendaGuests == [guest])
        try await session.reconcileParticipants(roster(6, isAnonymous: true), local: local)
        #expect(await session.activities.agendaGuests == nil)
        await session.close()
    }

    @Test(arguments: [false, true])
    func refreshReturnsIndependentlyAndFilesBelongToTheJoinedCall(endBeforeReply: Bool) async throws {
        let transport = HeldAgendaArtifactsTransport()
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        await session.setActivitiesHandler { _ in }
        while await !transport.started {
            await Task.yield()
        }
        let read = try #require(await session.agendaArtifactRead)
        try await session.performActivity(CallActivity("refresh"))
        #expect(await transport.agendaRequests == 1)
        if endBeforeReply {
            await session.close()
        }
        await transport.release()
        await read.value
        let files = await session.activities.artifactFiles
        let attachments = await session.activities.agendaAttachments
        if endBeforeReply {
            #expect(files.isEmpty)
            #expect(attachments == nil)
        } else {
            #expect(files.first?.kind == "recording")
            #expect(files.first?.url.absoluteString == "https://drive.google.com/file/d/synthetic/view")
            #expect(attachments?.map(\.title) == ["Agenda"])
            #expect(attachments?.first?.url
                .absoluteString == "https://docs.google.com/document/d/agenda/edit")
            await session.close()
            #expect(await session.activities.artifactFiles.isEmpty)
            #expect(await session.activities.agendaAttachments == nil)
        }
        #expect(await transport.agendaRequests == 1)
    }

    private func roster(
        _ revision: UInt64, guestState: UInt64? = nil, isAnonymous: Bool = false
    ) throws -> MeetCallCollectionsWire.Devices {
        let base = NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, 1)
        let local = base + NativeMeetFixture.string(49, "1200")
            + (isAnonymous ? NativeMeetFixture.number(15, 1) : Data())
        let guest = guestState.map { state in
            NativeMeetFixture.string(1, "spaces/demo/devices/two") + NativeMeetFixture.number(4, state)
                + NativeMeetFixture.string(43, "Taylor@example.test")
        }
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, revision))
        let collection = metadata + NativeMeetFixture.bytes(2, local)
            + (guest.map { NativeMeetFixture.bytes(2, $0) } ?? Data())
        let encoded = NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, collection)).base64EncodedData()
        return try #require(try MeetCallCollectionsWire.snapshot(from: encoded, in: "spaces/demo").devices)
    }
}

private actor HeldAgendaArtifactsTransport: HTTPTransport {
    let base = ScriptedTransport(NativeMeetFixture.responses())
    private var held: CheckedContinuation<Void, Never>?
    private(set) var agendaRequests = 0
    var started: Bool {
        held != nil
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.url.lastPathComponent {
        case "GetUser", "GetSmartNotesEligibilities", "SyncMeetingSpaceCollections":
            return try NativeMeetFixture.ok(Data()).get()
        case "FetchCalendarEvent":
            #expect(request.headers["x-goog-meeting-token"] == "30;joined")
            #expect(request.timeout == .seconds(5))
            agendaRequests += 1
            await withCheckedContinuation { held = $0 }
            let link = NativeMeetFixture.string(1, "https://drive.google.com/file/d/synthetic/view")
            let file = link + NativeMeetFixture.number(6, 3) + NativeMeetFixture.number(7, 1)
            let attachment = NativeMeetFixture.string(1, "https://docs.google.com/document/d/agenda/edit")
                + NativeMeetFixture.string(2, "Agenda") + NativeMeetFixture.number(6, 1)
            let guest = NativeMeetFixture.string(1, "taylor@example.test")
                + NativeMeetFixture.string(2, "Taylor") + NativeMeetFixture.number(5, 4)
            let event = NativeMeetFixture.bytes(19, file) + NativeMeetFixture.bytes(19, attachment)
                + NativeMeetFixture.bytes(14, guest)
            return try NativeMeetFixture.ok(NativeMeetFixture.bytes(1, event)).get()
        default:
            return try await base.send(request)
        }
    }

    func release() {
        held?.resume()
        held = nil
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }
}
