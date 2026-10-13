import Foundation
import GChatBridgeCore

/// Owns one native audio trial, including cleanup of a registration that
/// completes after cancellation. All provider objects remain in the bridge.
actor NativeMeetCallSession {
    private let client: MeetCallClient
    private let device: MeetDeviceSession
    private let media: any CallMediaEngine
    private let validateAccount: @Sendable () async throws -> Void
    private var connection: Task<Void, any Error>?
    private var ready = false
    private var closed = false
    private var cleanupAttempted = false
    private var registrationAttempted = false
    private var lines: [String] = []

    init(
        client: MeetCallClient, call: MeetResolvedCall, media: any CallMediaEngine,
        validateAccount: @escaping @Sendable () async throws -> Void
    ) {
        self.client = client
        device = MeetDeviceSession(client: client, call: call)
        self.media = media
        self.validateAccount = validateAccount
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
        try await check()
        guard ready, !closed, await media.isConnected else { throw MeetDeviceSessionError.mediaNotConnected }
        try await validateAccount()
        await device.setMediaConnected(media.isConnected)
        try await device.invite(calleeID: callee, requestID: UUID())
        try Task.checkCancellation()
        lines.append("CreateMeetingInvite: accepted from Kibble's joined native device")
    }

    func close() async {
        closed = true
        ready = false
        let task = connection
        task?.cancel()
        await media.close()
        _ = await task?.result
        await cleanup()
    }

    private func performConnect() async throws {
        do {
            try await check()
            lines.append("Native audio: preparing local offer")
            let local = try await media.makeAudioOffer(serverControlChannel: "collections")
            let offer = try MeetAudioOffer(
                sdp: local.sdp, srtpSuite: Self.suite(local.srtpProfile), collections: true
            )
            try await check()
            reportOffer(local)
            lines.append("CreateMediaSession: started")
            let session = try await client.createMediaSession(clientConfiguration: offer.clientConfiguration)
            try await check()
            lines.append("CreateMediaSession: accepted (media credentials withheld)")
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
            ready = true
            lines.append("UpdateMeetingDevice: JOINED accepted")
        } catch {
            if case let MeetCallClientError.httpStatus(_, refusal) = error {
                lines.append("Meet error message diagnostic: " + refusal.messageKind.rawValue
                    + " (raw message withheld)")
            }
            lines.append("Native join: " + MeetDMCallTrial.errorDescription(error))
            ready = false
            closed = true
            await media.close()
            await cleanup()
            throw error
        }
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

    private func check() async throws {
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
