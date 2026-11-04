import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BreakoutCallHandoffTests {
    @Test func aRoomJoinsOnlyAfterConfirmedParentTerminationAndCanReturn() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        let main = try #require(URL(string: "https://meet.example.test/main"))
        _ = calls.joinMeeting(at: main)
        #expect(await eventually { calls.call?.phase == .connected && calls.interaction?.activities != nil })
        let room = try #require(calls.interaction?.activities?.rooms.first)
        try await calls.joinBreakoutRoom(room.id)
        #expect(await eventually { calls.call?.phase == .connected && service.joined.count == 2 })
        #expect(service.operations == ["join", "end", "join"])
        #expect(calls.breakoutReturnURL == main)
        try await calls.returnFromBreakoutRoom()
        #expect(await eventually { calls.call?.phase == .connected && service.joined.count == 3 })
        #expect(service.joined.last == main && calls.breakoutReturnURL == nil)
        await calls.stop()
    }

    @Test func stoppingTheAccountDuringAHeldHandoffNeverJoinsAnotherMeeting() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        _ = try calls.joinMeeting(at: #require(URL(string: "https://meet.example.test/main")))
        #expect(await eventually { calls.call?.phase == .connected && calls.interaction?.activities != nil })
        let room = try #require(calls.interaction?.activities?.rooms.first)
        service.holdCleanup = true
        let handoff = Task { try await calls.joinBreakoutRoom(room.id) }
        #expect(await eventually { service.operations.last == "end" })
        await calls.stop()
        service.holdCleanup = false
        await #expect(throws: CancellationError.self) { try await handoff.value }
        #expect(service.joined.count == 1 && calls.call == nil && calls.breakoutReturnURL == nil)
    }

    @Test func invalidLinkRefusalNamesTheInputProblemAndKeepsItsDiagnosticCode() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        service.joinFailure = ServiceFailure(code: "invalidRequest", details: .object([
            "callStage": .string("meetingLinkNormalization")
        ]))
        calls.start(service: service)
        #expect(await eventually { calls.canJoinMeetingLinks })
        let url = try #require(URL(string: "https://meet.example.test/room"))
        let id = try #require(calls.joinMeeting(at: url))
        #expect(await eventually { calls.call?.phase == .failed })
        #expect(calls.call?.failureMessage?.contains("meeting link isn’t supported") == true)
        #expect(calls.diagnosticReport(callID: id)?.contains("Call control failure: invalidRequest") == true)
        #expect(calls.diagnosticReport(callID: id)?
            .contains("Call failure stage: meetingLinkNormalization") == true)
        #expect(calls.diagnosticReport(callID: id)?.contains("Call target: meetingLink") == true)
        #expect(calls.diagnosticReport(callID: id)?.contains("advertised host=true") == true)
        #expect(calls.diagnosticReport(callID: id)?.contains("example") == false)
        #expect(calls.diagnosticReport(callID: UUID()) == nil)
        service.joinFailure = nil
        let replacement = try #require(calls.joinMeeting(at: url))
        #expect(await eventually { calls.call?.phase == .connected })
        #expect(calls.diagnosticReport(callID: id) == nil)
        #expect(calls.diagnosticReport(callID: replacement)?.contains("Call failure stage") == false)
        await calls.stop()
        #expect(calls.diagnosticReport(callID: replacement) == nil)
    }

    @Test func failedCleanupNeverStartsTheRoom() async throws {
        let service = RoomCallService(), calls = AudioCallController()
        calls.start(service: service)
        _ = try calls.joinMeeting(at: #require(URL(string: "https://meet.example.test/main")))
        #expect(await eventually { calls.call?.phase == .connected && calls.interaction?.activities != nil })
        let room = try #require(calls.interaction?.activities?.rooms.first)
        service.failCleanup = true
        await #expect(throws: CancellationError.self) { try await calls.joinBreakoutRoom(room.id) }
        #expect(service.joined.count == 1)
        #expect(calls.breakoutReturnURL == nil)
        await calls.stop()
    }
}

@MainActor
private final class RoomCallService: MeetingLinkAudioCallService {
    let events: AsyncStream<AudioCallEvent>
    let sink: AsyncStream<AudioCallEvent>.Continuation
    var call: ConversationCallSnapshot?
    var operations: [String] = []
    var joined: [URL] = []
    var failCleanup = false
    var holdCleanup = false
    var joinFailure: ServiceFailure?
    var canJoinMeetingLinks: Bool {
        true
    }

    var meetingLinkHosts: Set<String> {
        ["meet.example.test"]
    }

    init() {
        (events, sink) = AsyncStream.makeStream()
    }

    func startListening() async throws {
        sink.yield(.listenerChanged(isListening: true))
    }

    func startOutgoing(to _: AudioCallRecipient, callID _: UUID) async throws {
        throw CancellationError()
    }

    func accept(callID _: UUID) async throws {
        throw CancellationError()
    }

    func decline(callID _: UUID) async throws {
        throw CancellationError()
    }

    func setMuted(_: Bool, callID _: UUID) async throws {}
    func stop() async {}
    func joinMeeting(at url: URL, callID: UUID) async throws {
        if let joinFailure {
            throw joinFailure
        }
        operations.append("join"); joined.append(url)
        let target = ConversationCallTarget(meetingURL: url, displayName: "Meeting")
        let value = ConversationCallSnapshot(id: callID, target: target, phase: .connected)
        call = value; sink.yield(.meetingSnapshot(value))
        var activities = CallActivitiesState()
        activities.rooms = [CallBreakoutRoom(
            id: UUID(),
            name: "Room",
            isOpen: true,
            joinURL: URL(string: "https://meet.example.test/room")
        )]
        var interaction = CallInteractionState(joinURL: url)
        interaction.activities = activities
        sink.yield(.interactionChanged(callID: callID, state: interaction))
    }

    func hangUp(callID: UUID) async throws {
        guard var value = call, value.id == callID else { throw CancellationError() }
        operations.append("end")
        while holdCleanup {
            try await Task.sleep(for: .milliseconds(1))
        }
        value.phase = .ended
        value.failureMessage = failCleanup ? "Cleanup unconfirmed." : nil
        sink.yield(.meetingSnapshot(value))
    }
}
