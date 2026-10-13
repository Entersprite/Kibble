import Foundation
import GChatBridgeCore

/// Owns one native audio trial, including cleanup of a registration that
/// completes after cancellation. All provider objects remain in the bridge.
actor NativeMeetCallSession {
    let client: MeetCallClient
    let device: MeetDeviceSession
    let media: any CallMediaEngine
    let now: @Sendable () -> ContinuousClock.Instant
    let validateAccount: @Sendable () async throws -> Void
    var connection: Task<Void, any Error>?
    var ready = false
    var closed = false
    private var cleanupAttempted = false
    private var registrationAttempted = false
    var lines: [String] = []
    var monitor: Task<Void, Never>?
    var refresh: Task<MeetCallCollectionsWire.Snapshot, any Error>?
    var closing: Task<Void, Never>?
    var receiveState: (@Sendable (MeetNativeCallState) async -> Void)?
    var state: MeetNativeCallState = .ready
    var stableState: MeetNativeCallState = .ready
    var deviceVersion: UInt64?
    var verifiedDeviceVersion: UInt64?
    var verifiedAloneDeviceVersion: UInt64?
    var invitationVersion: UInt64?
    var outgoingInvitationStatus: UInt64?
    var peerJoined = false
    var localObserved = false
    var invitationSeen = false
    var needsRefresh = true
    var pollTicks = 0
    var ringingDeadline: ContinuousClock.Instant?
    var disconnectedAt: ContinuousClock.Instant?
    var audioStream: MeetAudioStreamWire.Stream?
    var streamRequestID: UInt64 = 0
    var streamTask: Task<Bool, Never>?
    var muteRevision: UInt64 = 0
    var desiredMuted = false
    var mediaSessionName = ""

    init(
        client: MeetCallClient, call: MeetResolvedCall, media: any CallMediaEngine,
        validateAccount: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.client = client
        device = MeetDeviceSession(client: client, call: call)
        self.media = media
        self.validateAccount = validateAccount
        self.now = now
    }

    func takeReport() -> [String] {
        defer { lines.removeAll() }
        return lines
    }

    func connect() async throws {
        guard connection == nil, !ready, !closed else { throw MeetDeviceSessionError.closed }
        let task = Task { try await performConnect() }
        connection = task
        defer { connection = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func invite(callee: String) async throws {
        guard ready, !closed, connection == nil else { throw MeetDeviceSessionError.notJoined }
        let task = Task { try await performInvite(callee: callee) }
        connection = task
        defer { connection = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performInvite(callee: String) async throws {
        // A background read must not consume an explicit Ring click as busy.
        // Mark the invitation operation in flight first, then settle that read.
        _ = await refresh?.result
        try await check()
        guard ready, !closed, await media.isConnected else { throw MeetDeviceSessionError.mediaNotConnected }
        try await validateAccount()
        await device.setMediaConnected(media.isConnected)
        try await device.invite(calleeID: callee, requestID: UUID())
        try Task.checkCancellation()
        lines.append("CreateMeetingInvite: accepted from Kibble's joined native device")
        ringingDeadline = now().advanced(by: .seconds(36))
        await publish(.ringing)
    }

    func close(reason: MeetNativeCallEndReason = .localEnded) async {
        if let closing {
            await closing.value; return
        }
        let task = Task { await performClose(reason: reason) }
        closing = task
        await task.value
    }

    private func performClose(reason: MeetNativeCallEndReason) async {
        closed = true
        ready = false
        monitor?.cancel()
        monitor = nil
        let task = connection
        let refresh = refresh
        task?.cancel()
        refresh?.cancel()
        streamTask?.cancel()
        await media.setEventHandler(nil)
        await media.close()
        await publish(.ending)
        _ = await task?.result
        _ = await refresh?.result
        _ = await streamTask?.result
        audioStream = nil
        mediaSessionName = ""
        await cleanup()
        await publish(.ended(reason))
        receiveState = nil
    }

    private func performConnect() async throws {
        do {
            try await check()
            lines.append("Native audio: preparing local offer")
            let supportsStreamControl = await media.supportsStreamControl
            let local = try await media.makeAudioOffer(serverControlChannel: "collections")
            let offer = try MeetAudioOffer(
                sdp: local.sdp, srtpSuite: Self.suite(local.srtpProfile), collections: true,
                streamControl: supportsStreamControl
            )
            try await check()
            reportOffer(local)
            if supportsStreamControl {
                lines.append("Native control: dcrpc requested; ordered, reliable and uncompressed")
            }
            lines.append("CreateMediaSession: started")
            let session = try await client.createMediaSession(clientConfiguration: offer.clientConfiguration)
            try await check()
            lines.append("CreateMediaSession: accepted (media credentials withheld)")
            mediaSessionName = session.name
            lines.append("Native audio: converting server answer")
            let answer = try serverAnswer(offer, configuration: session.serverConfiguration)
            lines.append("CreateMeetingDevice: started")
            registrationAttempted = true
            try await device.register(mediaSession: session.name)
            lines.append("CreateMeetingDevice: accepted")
            try await check()
            try await media.applyAnswer(answer)
            lines.append("Native audio: remote answer applied; waiting for transport and control channel")
            try await media.waitUntilConnected(timeout: .seconds(20))
            try await check()
            guard await media.isConnected else { throw CallMediaError.connectionFailed }
            await device.setMediaConnected(true)
            lines.append("Native audio: peer transport connected")
            lines.append("Native control: collections channel open")
            try await device.join()
            try await check()
            guard await media.isConnected else { throw CallMediaError.connectionFailed }
            try await finishConnect(offer, streamControl: supportsStreamControl)
        } catch {
            await handleConnectFailure(error)
            throw error
        }
    }

    private func handleConnectFailure(_ error: any Error) async {
        if case let MeetCallClientError.httpStatus(_, refusal) = error {
            lines.append("Meet error message diagnostic: " + refusal.messageKind.rawValue
                + " (raw message withheld)")
        }
        lines.append("Native join: " + MeetDMCallTrial.errorDescription(error))
        ready = false
        closed = true
        audioStream = nil
        mediaSessionName = ""
        await media.close()
        await cleanup()
    }

    private func finishConnect(_ offer: MeetAudioOffer, streamControl: Bool) async throws {
        lines.append("UpdateMeetingDevice: JOINED accepted")
        if streamControl {
            await registerAudioStream(offer)
            try await check()
            guard audioStream != nil else { throw CallMediaError.outgoingAudioUnconfirmed }
        }
        ready = true
    }

    private static func suite(_ profile: CallSRTPProfile) -> MeetAudioOffer.SRTPSuite {
        switch profile {
        case .aes128SHA180: .aes128SHA180
        case .aeadAES128GCM: .aeadAES128GCM
        case .aeadAES256GCM: .aeadAES256GCM
        }
    }

    private func reportOffer(_ local: CallAudioOffer) {
        lines.append("Native audio: local offer prepared (SDP withheld)")
        lines.append("Native audio codecs: Opus with optional RED; legacy codecs excluded")
        lines.append("Native control: server-created collections channel; protobuf; uncompressed")
        lines.append("Native audio config: DTLS selector 1; media selector 2; audio output enabled; SRTP "
            + local.srtpProfile.rawValue)
    }

    private func serverAnswer(_ offer: MeetAudioOffer, configuration: Data) throws -> String {
        do {
            return try offer.answer(serverConfiguration: configuration)
        } catch {
            if let failure = error as? MeetAudioOffer.AnswerFailure, failure == .ice {
                lines += MeetAudioOffer.iceDiagnostics(serverConfiguration: configuration)
            }
            throw error
        }
    }

    func check() async throws {
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        try await validateAccount()
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
    }

    private func cleanup() async {
        guard !cleanupAttempted else { return }
        cleanupAttempted = true
        // A cancelled connection task cannot carry its cancelled transport
        // into the leave request. Settle registration first, then leave once.
        let device = device
        do {
            try await Task.detached { try await device.cancelInvitation() }.value
            lines.append("Native cleanup: invitation cancellation settled or no invitation remained")
        } catch {
            lines.append("Native cleanup: invitation cancellation unconfirmed; "
                + MeetDMCallTrial.errorDescription(error))
        }
        do {
            try await Task.detached { try await device.leave() }.value
            lines.append(registrationAttempted
                ? "Native cleanup: local media closed; device leave settled"
                : "Native cleanup: local media closed; caller device registration was not attempted")
        } catch {
            lines
                .append("Native cleanup: device leave unconfirmed; " + MeetDMCallTrial
                    .errorDescription(error))
        }
    }
}
