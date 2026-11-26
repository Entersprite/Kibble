import ChatKit
import Foundation
import GChatBridgeCore
import Synchronization
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetGuestAdmissionTests {
    private static let own = "spaces/demo/devices/one"

    @Test func waitingGuestsSeeOnlyAddressedMessagesAndLoseThemOnAdmission() async throws {
        let waiting = waitingMessage("waiting", text: "Please wait", recipient: 2)
        let publicMessage = waitingMessage("public", text: "In-call message", recipient: 0)
        let foreign = waitingMessage("foreign", text: "Not this audience", recipient: 5)
        let wrongDevice = NativeMeetFixture.string(1, "spaces/demo/devices/browser")
            + NativeMeetFixture.number(4, 13)
        let older = waitingMessage("older", text: "Stale message", recipient: 2)
        let final = waitingMessage("final", text: "After admission", recipient: 2)
        let polls = [
            Self.collection(1, [Self.device(13)], history: (1, [waiting])),
            Self.collection(2, [wrongDevice], history: (3, [final])),
            Self.collection(3, [Self.device(13)], history: (3, [publicMessage, waiting, foreign])),
            Self.collection(4, [Self.device(13)], history: (2, [older])),
            Self.collection(5, [Self.device(1)], history: (4, [final]))
        ]
        let (session, transport) = try await setup(3, polls)
        let messages = GuestMessages()
        await session.setAdmissionHandler(nil, waitingRoomMessages: { await messages.append($0) })
        try await session.connect()
        #expect(await messages.values.map { $0.map(\.text) } == [["Please wait"]])
        #expect(await session.activities.waitingRoomMessages == nil)
        #expect(await session.activities.messages.isEmpty)
        #expect(await !session.activities.availableActions.contains("chatWaitingRoom"))
        let requests = await Array(transport.sent.dropFirst(4))
        #expect(requests.count == polls.count)
        #expect(requests.first?.body.map { ProtoFieldScan.payloads(ofField: 4, in: $0) } == [])
        #expect(requests.dropFirst().allSatisfy {
            $0.body.map { ProtoFieldScan.payloads(ofField: 4, in: $0) } == [Data()]
        })
        await session.close()
    }

    @Test func aFailedOptionalWaitingChatReadFallsBackToTheAdmissionRead() async throws {
        let rejected = Result<HTTPResponse, any Error>.success(
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
        )
        let poll = Self.collection(1, [Self.device(1)])
        let (session, transport) = try await setup(13, [rejected, poll])
        let messages = GuestMessages()
        await session.setAdmissionHandler(nil, waitingRoomMessages: { await messages.append($0) })
        try await session.connect()
        #expect(await messages.values.isEmpty)
        #expect(await session.ready)
        let requests = await Array(transport.sent.dropFirst(4))
        #expect(requests.first?.body.map { ProtoFieldScan.payloads(ofField: 4, in: $0) } == [Data()])
        #expect(requests.last?.body.map { ProtoFieldScan.payloads(ofField: 4, in: $0) } == [])
        await session.close()
        #expect(await transport.sent.count == 7)
    }

    @Test func waitingNeedsANewerFullReadOfTheSameRegistrationToProceed() async throws {
        let wrongDevice = NativeMeetFixture.string(1, "spaces/demo/devices/browser")
            + NativeMeetFixture.number(4, 1)
        let polls = [
            Self.collection(4, [Self.device(3), wrongDevice]),
            Self.collection(4, [Self.device(1)]),
            Self.collection(3, [Self.device(1)]),
            Self.collection(5, [wrongDevice]),
            Self.collection(6, [Self.device(13)]),
            Self.collection(7, [Self.device(1)])
        ]
        let clock = GuestAdmissionClock()
        let media = NativeFakeMedia()
        let ordinaryReads = [Self.collection(6, [Self.device(13)]), Self.collection(7, [Self.device(1)])]
        let (session, transport) = try await setup(3, polls + ordinaryReads, media: media, clock: clock)
        let states = GuestStates()
        await session.setAdmissionHandler { await states.append($0) }
        try await session.connect()
        #expect(await states.values == [
            .awaitingAdmission(.requestPending), .awaitingAdmission(.waitingRoom), .ready
        ])
        #expect(await session.ready && !media.isMicrophoneMuted)
        #expect(clock.delays == Array(repeating: .seconds(5), count: 6))
        let requests = await transport.sent
        #expect(requests[2].url.lastPathComponent == "CreateMeetingDevice")
        let registration = try #require(requests[2].body)
        let registeredDevice = try #require(ProtoFieldScan.payloads(ofField: 2, in: registration).first)
        #expect(ProtoFieldScan.payloads(ofField: 39, in: registeredDevice) == [Data([22])])
        #expect(requests.dropFirst(4).count == polls.count)
        #expect(requests.dropFirst(4).allSatisfy {
            $0.url.lastPathComponent == "SyncMeetingSpaceCollections"
                && $0.body == NativeMeetFixture.string(1, "spaces/demo") + NativeMeetFixture.bytes(3, Data())
        })
        #expect(try await session.device.collections().devices == nil)
        await session.refreshState()
        #expect(await session.state == .active)
        await session.close()
        #expect(await session.cleanupStatus.isConfirmed)
    }

    @Test(arguments: [UInt64(4), 11], [true, false])
    func denialAndCapacitySettleTheExactRegistration(_ terminal: UInt64, fromJoinReply: Bool) async throws {
        let media = NativeFakeMedia()
        let polls = fromJoinReply ? [] : [Self.collection(1, [Self.device(terminal)])]
        let (session, transport) = try await setup(
            fromJoinReply ? terminal : 13,
            polls,
            media: media
        )
        await #expect(throws: terminal == 4 ? NativeMeetAdmissionError.denied : .full) {
            try await session.connect()
        }
        #expect(!media.isConnected)
        #expect(await !session.ready)
        #expect(await session.cleanupStatus.isConfirmed)
        #expect(await session.device.localDeviceName == nil)
        #expect(await transport.sent.dropFirst(4).map(\.url.lastPathComponent)
            == (fromJoinReply ? [] : ["SyncMeetingSpaceCollections"]))
        await session.close()
        #expect(await transport.sent.count == 4 + polls.count)
    }

    @Test func staleAndForeignDenialsLeaveTheActualPendingRegistration() async throws {
        let foreign = NativeMeetFixture.string(1, "spaces/demo/devices/browser")
            + NativeMeetFixture.number(4, 4)
        let forbidden = HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
        let polls = [
            Self.collection(3, [Self.device(3)]),
            Self.collection(2, [Self.device(4)]),
            Self.collection(4, [foreign]),
            .success(forbidden)
        ]
        let (session, transport) = try await setup(3, polls)
        await #expect(throws: MeetCallClientError.self) { try await session.connect() }
        let requests = await transport.sent.dropFirst(4)
        #expect(requests.map(\.url.lastPathComponent) == [
            "SyncMeetingSpaceCollections", "SyncMeetingSpaceCollections", "SyncMeetingSpaceCollections",
            "SyncMeetingSpaceCollections", "UpdateMeetingDevice"
        ])
        #expect(try requests.last?.body == MeetDeviceWire.leave(device: Self.own))
        #expect(await session.cleanupStatus.isConfirmed)
    }

    @Test func admissionAfterWaitingStillRequiresExplicitConsentForANewNotice() async throws {
        let requirement = NativeMeetFixture.number(1, 1) + NativeMeetFixture.number(2, 1)
        let notice = Self.collection(1, [Self.device(9) + NativeMeetFixture.bytes(41, requirement)])
        let reply = NativeMeetFixture.ok(Self.device(1))
        let transport = ScriptedTransport(responses(3, [notice, notice, reply]))
        let media = StreamFakeMedia()
        media.admissionConfirmation = { [weak media] notices in
            #expect(notices == [.recording])
            #expect(media?.isMicrophoneMuted == true && media?.requests.isEmpty == true)
            return true
        }
        let session = try await NativeMeetFixture.session(
            transport, media: media, staysWhenAlone: true, admissionSleep: { _ in }
        )
        try await session.connect()
        #expect(media.admissionNotices == [[.recording]])
        #expect(media.requests.count == 1 && !media.isMicrophoneMuted)
        let writes = await transport.sent.filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
        #expect(writes.count == 2)
        let accepted = NativeMeetFixture.number(1, 1) + NativeMeetFixture.number(2, 2)
        let patch = NativeMeetFixture.string(1, Self.own) + NativeMeetFixture.bytes(41, accepted)
        #expect(writes.last?.body == NativeMeetFixture.bytes(1, patch))
        await session.close()
        #expect(await session.cleanupStatus.isConfirmed)
    }

    @Test func exactCompatibilityRejectionDuringAdmissionSettlesTheDevice() async throws {
        let media = NativeFakeMedia()
        let rejected = Self.device(8) + NativeMeetFixture.number(9, 1) + NativeMeetFixture.number(28, 1)
        let (session, transport) = try await setup(3, [
            Self.collection(1, [Self.device(3)]), Self.collection(2, [rejected])
        ], media: media)
        await #expect(throws: NativeMeetAdmissionError.incompatibleClient) { try await session.connect() }
        #expect(!media.isConnected)
        #expect(await session.cleanupStatus.isConfirmed)
        #expect(await session.device.localDeviceName == nil)
        #expect(await transport.sent.dropFirst(4).map(\.url.lastPathComponent) == [
            "SyncMeetingSpaceCollections", "SyncMeetingSpaceCollections"
        ])
    }

    @Test(arguments: [UInt64(3), 13])
    func joinRequestsExpireWhileWaitingRoomsMayOutlastTenMinutes(_ initialState: UInt64) async throws {
        let clock = GuestAdmissionClock(step: .seconds(601))
        let polls = initialState == 3 ? [] : [Self.collection(1, [Self.device(1)])]
        let (session, transport) = try await setup(initialState, polls, clock: clock)
        if initialState == 3 {
            await #expect(throws: NativeMeetAdmissionError.timedOut) { try await session.connect() }
            #expect(await transport.sent.count == 5)
        } else {
            try await session.connect()
            #expect(await transport.sent.last?.url.lastPathComponent == "SyncMeetingSpaceCollections")
        }
        await session.close()
        #expect(await session.cleanupStatus.isConfirmed)
    }

    @Test func cancellationDuringAnInFlightCheckDiscardsLateAdmissionBeforeLeave() async throws {
        let base = ScriptedTransport(responses(3, [Self.collection(1, [Self.device(1)])]))
        let transport = NativeHoldRegistration(base, method: "SyncMeetingSpaceCollections")
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(
            transport, media: media, staysWhenAlone: true, admissionSleep: { _ in }
        )
        let joining = Task { try await session.connect() }
        while await !transport.started {
            await Task.yield()
        }
        #expect(media.isMicrophoneMuted)
        #expect(await session.state == .awaitingAdmission(.requestPending))
        let closing = Task { await session.close() }
        while media.calls.last != "close" {
            await Task.yield()
        }
        await transport.release()
        await closing.value
        await #expect(throws: CancellationError.self) { try await joining.value }
        #expect(await session.state == .ended(.localEnded))
        #expect(await !session.ready)
        #expect(await session.cleanupStatus.isConfirmed)
        #expect(await base.sent.count == 6)
    }

    private func setup(
        _ state: UInt64, _ polls: [Result<HTTPResponse, any Error>],
        media: NativeFakeMedia = NativeFakeMedia(),
        clock: GuestAdmissionClock = GuestAdmissionClock()
    ) async throws -> (NativeMeetCallSession, ScriptedTransport) {
        let transport = ScriptedTransport(responses(state, polls))
        let session = try await NativeMeetFixture.session(
            transport, media: media, staysWhenAlone: true,
            now: { clock.now }, admissionSleep: { clock.advance($0) }
        )
        return (session, transport)
    }

    private func responses(_ state: UInt64, _ polls: [Result<HTTPResponse, any Error>])
        -> [Result<HTTPResponse, any Error>] {
        var setup = NativeMeetFixture.responses(joinedState: state)
        setup[2] = setup[2].map { response in
            var response = response
            response.headers = HTTPHeaders(fields: response.headers.fields + [
                .init(name: "X-Goog-Meeting-Debugid", value: "conference-sentinel")
            ])
            return response
        }
        return Array(setup.prefix(4)) + polls + Array(setup.suffix(1))
    }

    static func device(_ state: UInt64) -> Data {
        NativeMeetFixture.string(1, own) + NativeMeetFixture.number(4, state)
    }

    static func collection(
        _ revision: UInt64, _ devices: [Data], history: (UInt64, [Data])? = nil
    ) -> Result<HTTPResponse, any Error> {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, revision))
        let payload = devices.reduce(into: metadata) { $0 += NativeMeetFixture.bytes(2, $1) }
        let roster = NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, payload))
        let messages = history.map { revision, entries in
            let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, revision))
            let full = entries.reduce(into: metadata) { $0 += NativeMeetFixture.bytes(2, $1) }
            return NativeMeetFixture.bytes(3, NativeMeetFixture.bytes(2, full))
        } ?? Data()
        return NativeMeetFixture.ok(roster + messages)
    }

    private func waitingMessage(_ name: String, text: String, recipient: UInt64) -> Data {
        NativeMeetFixture.string(1, name) + NativeMeetFixture.bytes(5, NativeMeetFixture.string(1, text))
            + NativeMeetFixture.number(6, 1) + NativeMeetFixture.number(10, recipient)
    }
}

private actor GuestMessages {
    var values: [[CallMeetingMessage]] = []
    func append(_ value: [CallMeetingMessage]) {
        values.append(value)
    }
}

private actor GuestStates {
    var values: [MeetNativeCallState] = []
    func append(_ value: MeetNativeCallState) {
        values.append(value)
    }
}

private final class GuestAdmissionClock: Sendable {
    private let instant = Mutex<ContinuousClock.Instant>(.now)
    private let recorded = Mutex<[Duration]>([])
    private let step: Duration?

    init(step: Duration? = nil) {
        self.step = step
    }

    var now: ContinuousClock.Instant {
        instant.withLock { $0 }
    }

    var delays: [Duration] {
        recorded.withLock { $0 }
    }

    func advance(_ duration: Duration) {
        recorded.withLock { $0.append(duration) }
        instant.withLock { $0 += step ?? duration }
    }
}
