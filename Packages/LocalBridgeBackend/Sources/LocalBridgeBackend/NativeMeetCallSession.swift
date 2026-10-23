import ChatKit
import Foundation
import GChatBridgeCore

/// Owns one native audio trial, including cleanup of a registration that
/// completes after cancellation. All provider objects remain in the bridge.
actor NativeMeetCallSession {
    let client: MeetCallClient
    let device: MeetDeviceSession
    let staysWhenAlone: Bool
    let media: any CallMediaEngine
    let now: @Sendable () -> ContinuousClock.Instant
    let validateAccount: @Sendable () async throws -> Void
    var connection: Task<Void, any Error>?
    var ready = false
    var closed = false
    var cleanupStatus = MeetNativeCallCleanup()
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
    var participantLocalDevice: String?
    var participantMutes: [String: Bool] = [:]
    var publishedParticipants: [CallParticipantDevice]?
    var participantHandles: [String: UUID] = [:]
    var participantDevices: [String: MeetDeviceWire.Device] = [:]
    var receiveParticipants: (@Sendable ([CallParticipantDevice]?) async -> Void)?
    var peerJoined = false
    var localObserved = false
    var invitationSeen = false
    var needsRefresh = true
    var pollTicks = 0
    var ringingDeadline: ContinuousClock.Instant?
    var disconnectedAt: ContinuousClock.Instant?
    var isSuspended = false
    var audioStream: MeetAudioStreamWire.Stream?
    var streamRequestID: UInt64 = 0
    var streamTask: Task<Bool, Never>?
    var muteRevision: UInt64 = 0
    var desiredMuted = false
    var mediaSessionName = ""
    var ownPresentationSources: [MeetVideoSource] = []
    var presentationStart: Task<Void, any Error>?
    var presentation: NativeMeetPresentation?
    var videoContext: MeetVideoStreamWire.Context?
    var videoConfiguration: Data?
    var receivingVideo: MeetVideoStreamWire.Downstream?
    var receivingVideos: [MeetVideoStreamWire.Downstream?] = []
    var viewedVideos: [MeetVideoStreamWire.Downstream] = []
    var receivingVideoCapacity = 1
    var videoPoll: Task<Void, Never>?
    var cameraMuted = true
    var viewedVideo: MeetVideoStreamWire.Downstream?
    var videoSource: MeetVideoSource?
    var videoStatus: String?
    /// Set only when the camera stream could not be registered, so the poll
    /// searches for the remote microphone alone.
    var audioSearchContext: MeetVideoStreamWire.Context?
    var remoteAudioMuted: Bool?
    var receiveRemoteMuted: (@Sendable (Bool?) async -> Void)?

    init(
        client: MeetCallClient, call: MeetResolvedCall, media: any CallMediaEngine,
        staysWhenAlone: Bool = false,
        validateAccount: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.client = client
        device = MeetDeviceSession(client: client, call: call)
        self.media = media
        self.staysWhenAlone = staysWhenAlone
        self.validateAccount = validateAccount
        self.now = now
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
        let mediaWasClosed = closed
        closed = true
        ready = false
        monitor?.cancel()
        monitor = nil
        let task = connection
        let refresh = refresh
        task?.cancel()
        refresh?.cancel()
        streamTask?.cancel()
        presentationStart?.cancel()
        let videoPoll = videoPoll
        self.videoPoll = nil
        videoPoll?.cancel()
        await media.configureScreenSharing(start: nil, stop: nil)
        await media.configureCamera(announce: nil)
        await media.setEventHandler(nil)
        if !mediaWasClosed {
            await media.close()
        }
        await publish(.ending)
        _ = await task?.result
        _ = await refresh?.result
        _ = await streamTask?.result
        _ = await videoPoll?.result
        audioStream = nil
        ownPresentationSources = []
        videoContext = nil
        audioSearchContext = nil
        videoSource = nil
        videoConfiguration = nil
        receivingVideo = nil
        receivingVideos = []
        viewedVideos = []
        viewedVideo = nil
        mediaSessionName = ""
        await stopPresentation()
        ownPresentationSources = []
        await cleanup()
        await publish(cleanupStatus.isConfirmed ? .ended(reason) : .endedUnconfirmed(reason, cleanupStatus))
        receiveState = nil
        receiveRemoteMuted = nil
    }

    private func performConnect() async throws {
        do {
            try await check()
            lines.append("Native audio: preparing local offer")
            let supportsStreamControl = await media.supportsStreamControl
            let local = try await media.makeAudioOffer(serverControlChannel: "collections")
            let video = try await media.supportsVideo ? MeetVideoOffer(
                sdp: local.sdp,
                srtpSuite: Self.suite(local.srtpProfile)
            ) : nil
            let offer = try video?.audio ?? MeetAudioOffer(
                sdp: local.sdp, srtpSuite: Self.suite(local.srtpProfile), collections: true,
                streamControl: supportsStreamControl
            )
            try await check()
            reportOffer(local)
            if supportsStreamControl {
                lines.append("Native control: dcrpc requested; ordered, reliable and uncompressed")
            }
            lines.append("CreateMediaSession: started")
            let session = try await client
                .createMediaSession(clientConfiguration: video?.clientConfiguration ?? offer
                    .clientConfiguration)
            try await check()
            lines.append("CreateMediaSession: accepted (media credentials withheld)")
            mediaSessionName = session.name
            lines.append("Native audio: converting server answer")
            let answer = try video?.answer(serverConfiguration: session.serverConfiguration)
                ?? serverAnswer(offer, configuration: session.serverConfiguration)
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
            try await prepareOptionalMedia(video, configuration: session.serverConfiguration)
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
        if !closed {
            closed = true
            await media.close()
        }
        audioStream = nil
        ownPresentationSources = []
        videoContext = nil
        audioSearchContext = nil
        videoSource = nil
        videoConfiguration = nil
        receivingVideo = nil
        receivingVideos = []
        viewedVideos = []
        viewedVideo = nil
        mediaSessionName = ""
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
            cleanupStatus.invitationUnconfirmed = true
            lines.append("Native cleanup: invitation cancellation unconfirmed; "
                + MeetDMCallTrial.errorDescription(error))
        }
        do {
            try await Task.detached { try await device.leave() }.value
            lines.append(registrationAttempted
                ? "Native cleanup: local media closed; device leave settled"
                : "Native cleanup: local media closed; caller device registration was not attempted")
        } catch {
            cleanupStatus.leaveUnconfirmed = true
            lines
                .append("Native cleanup: device leave unconfirmed; " + MeetDMCallTrial
                    .errorDescription(error))
        }
    }
}
