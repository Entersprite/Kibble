import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallStartupRetryTests {
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        try #require(await condition())
    }

    @Test func offlineStartupRetriesWithBoundedBackoffAndNoMediaOrInvites() async throws {
        let setup = try await LocalBridgeAudioCallServiceTests().setup(prefix: [
            .failure(ClassifiedTransportFailure(.notConnectedToInternet)),
            .success(HTTPResponse(status: 503, headers: HTTPHeaders([]), body: Data()))
        ])
        let gate = CallRetryGate()
        setup.service.retrySleep = { await gate.wait($0) }
        let starting = Task { try await setup.service.startListening() }
        try await wait { await gate.delays.count == 1 }
        #expect(setup.service.people.isEmpty)
        await gate.release()
        try await wait { await gate.delays.count == 2 }
        #expect(await gate.delays == [.seconds(3), .seconds(6)])
        await gate.release()
        try await starting.value
        #expect(setup.service.people.count == 1)
        #expect(setup.media.engines.isEmpty)
        #expect(await setup.base.sent.allSatisfy { !$0.url.path.contains("CreateMeeting") })
        await setup.service.stop()
    }

    @Test func watcherBootstrapRetryRetainsRecipientsAndAnOutgoingCall() async throws {
        let helper = LocalBridgeAudioCallServiceTests()
        var native = helper.nativeResponses(outgoing: true)
        let shell = LocalBridgeBackendTests.shell(app: "DynamiteWebUi").replacingOccurrences(
            of: "\"qwAQke\"",
            with: "\"wU9aJb\":\"KEY\",\"pZ68sc\":\"PROJECT\",\"ttqQxf\":\"TOPIC\",\"qwAQke\""
        )
        native.insert(ScriptedTransport.ok(shell), at: native.count - 2)
        let setup = try await helper.setup([
            .success(HTTPResponse(status: 503, headers: HTTPHeaders([]), body: Data()))
        ] + native, pushConfiguration: false)
        let gate = CallRetryGate()
        setup.service.retrySleep = { await gate.wait($0) }
        let starting = Task { try await setup.service.startListening() }
        try await wait { await gate.delays.count == 1 }
        let recipient = try helper.recipient(setup)
        let id = UUID()
        try await setup.service.startOutgoing(to: recipient, callID: id)
        let engine = try #require(setup.media.engines.first)
        await gate.release()
        try await starting.value
        #expect(setup.service.snapshot?.id == id)
        #expect(setup.service.snapshot?.phase == .ringing)
        #expect(!engine.closed)
        let sent = await setup.base.sent
        #expect(sent.filter { $0.url.path.hasSuffix("paginated_world") }.count == 1)
        #expect(sent.filter { $0.url.path.hasSuffix("CreateMeetingInvite") }.count == 1)
        try await setup.service.hangUp(callID: id)
        await setup.service.stop()
    }

    @Test func stopDrainsRetryAndNeverStartsAnotherRequestAfterTheAccountEnds() async throws {
        let setup = try await LocalBridgeAudioCallServiceTests().setup(prefix: [
            .failure(ClassifiedTransportFailure(.notConnectedToInternet))
        ])
        let gate = CallRetryGate()
        setup.service.retrySleep = { await gate.wait($0) }
        let starting = Task { try await setup.service.startListening() }
        try await wait { await gate.delays.count == 1 }
        let stopped = Task { await setup.service.stop() }
        try await wait { setup.service.isStopping }
        await gate.release()
        await stopped.value
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(await setup.base.sent.count == 1)
        #expect(setup.service.people.isEmpty)
        #expect(setup.service.incoming == nil)
    }

    @Test func authenticationAndSchemaFailuresDoNotRetryAndBackoffCaps() {
        #expect(!LocalBridgeAudioCallService.canRetryStartup(MeetDMCallTrialError.accountChanged))
        #expect(!LocalBridgeAudioCallService.canRetryStartup(MeetDMCallTrialError.signedOut))
        #expect(!LocalBridgeAudioCallService.canRetryStartup(MeetPushBootstrapError.invalidShell))
        #expect(!LocalBridgeAudioCallService.canRetryStartup(APIFailure.httpStatus(401)))
        #expect(LocalBridgeAudioCallService.startupRetryDelay(100) == .seconds(30))
    }
}

private actor CallRetryGate {
    var delays: [Duration] = []
    var pending: CheckedContinuation<Void, Never>?
    func wait(_ delay: Duration) async {
        delays.append(delay)
        await withCheckedContinuation { pending = $0 }
    }

    func release() {
        pending?.resume(); pending = nil
    }
}
