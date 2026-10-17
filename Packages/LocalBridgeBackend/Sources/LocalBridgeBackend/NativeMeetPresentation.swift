import Foundation
import GChatBridgeCore

/// A secondary device owns only presentation media. It never invites, polls
/// participant lifetime, or changes the main call's device.
actor NativeMeetPresentation {
    let client: MeetCallClient
    let device: MeetDeviceSession
    let media: any CallMediaEngine
    let validate: @Sendable () async throws -> Void
    var connection: Task<Void, any Error>?
    var closing: Task<Bool, Never>?
    enum Stage: String, Sendable {
        case offer = "local offer", mediaSession = "media session", registration = "device registration"
        case answer = "remote answer", transport = "transport connection", join = "device join"
        case stream = "stream registration", unmute = "stream unmute", ready
    }

    var stage = Stage.offer
    var cleanupFailure: String?
    var closed = false
    var source: MeetVideoSource?
    var context: MeetVideoStreamWire.Context?
    var requestID: UInt64 = 0

    init(
        client: MeetCallClient,
        device: MeetDeviceSession,
        media: any CallMediaEngine,
        validate: @escaping @Sendable () async throws -> Void
    ) {
        self.client = client; self.device = device; self.media = media; self.validate = validate
    }

    func connect() async throws {
        guard !closed, connection == nil else { throw CallMediaError.closed }
        let task = Task { try await performConnect() }
        connection = task
        defer { connection = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performConnect() async throws {
        try await check()
        let local = try await media.makeAudioOffer(serverControlChannel: "collections")
        let offer = try MeetVideoOffer(sdp: local.sdp)
        source = offer.source
        try await check()
        stage = .mediaSession
        let session = try await client.createMediaSession(clientConfiguration: offer.clientConfiguration)
        try await check()
        stage = .registration
        try await device.register(mediaSession: session.name)
        try await check()
        stage = .answer
        try await media.applyAnswer(offer.answer(serverConfiguration: session.serverConfiguration))
        stage = .transport
        try await media.waitUntilConnected(timeout: .seconds(20))
        try await check()
        guard await media.isConnected else { throw CallMediaError.connectionFailed }
        await device.setMediaConnected(true)
        stage = .join
        try await device.join()
        try await check()
        try await registerVideo(offer, session: session.name)
        await media.setEventHandler { [weak self] event in
            switch event {
            case .failed, .disconnected: _ = await self?.close()
            default: break
            }
        }
        try await check()
        stage = .ready
    }

    private func registerVideo(_ offer: MeetVideoOffer, session: String) async throws {
        stage = .stream
        guard let conference = await device.conferenceID else { throw CallMediaError.negotiationFailed }
        let context = try MeetVideoStreamWire.Context(mediaSession: session, conferenceID: conference)
        self.context = context
        requestID += 1
        let registration = try MeetVideoStreamWire.register(
            context: context, source: offer.source, camera: false,
            requestID: requestID, header: client.streamControlHeader()
        )
        let reply = try await exchange(registration)
        try MeetVideoStreamWire.confirm(
            from: reply,
            context: context,
            source: offer.source,
            muted: true,
            camera: false,
            requestID: requestID
        )
        stage = .unmute
        try await mute(false)
    }

    private func check() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CallMediaError.closed }
        try await validate()
        try Task.checkCancellation()
        guard !closed else { throw CallMediaError.closed }
    }

    private func exchange(_ request: Data) async throws -> Data {
        let id = requestID
        let reply = try await media.exchangeStreamControl(
            request,
            matches: { MeetAudioStreamWire.matchesRequest(
                $0,
                requestID: id
            ) },
            timeout: .seconds(8)
        )
        try await check()
        return reply
    }

    private func mute(_ muted: Bool) async throws {
        guard let context else { return }
        requestID += 1
        let request = try MeetVideoStreamWire.mute(
            context: context,
            muted: muted,
            requestID: requestID,
            header: client.streamControlHeader()
        )
        let reply = try await exchange(request)
        try MeetVideoStreamWire.confirm(from: reply, context: context, muted: muted, requestID: requestID)
    }

    func close() async -> Bool {
        if let closing {
            return await closing.value
        }
        closed = true
        let connection = connection
        connection?.cancel()
        let task = Task { [media, device] in
            await media.setEventHandler(nil)
            await media.close()
            _ = await connection?.result
            // Settle a late registration before leaving exactly once. Local
            // frames are already suppressed even when the acknowledgement fails.
            do {
                try await Task.detached { try await device.leave() }.value
                return true
            } catch {
                cleanupFailure = MeetDMCallTrial.errorDescription(error)
                return false
            }
        }
        closing = task
        return await task.value
    }
}
