import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func registerAudioStream(_ offer: MeetAudioOffer) async {
        do {
            try await check()
            let source = try offer.audioSource()
            lines.append("Native send audio: local sender track and SSRC validated (values withheld)")
            guard let conference = await device.conferenceID else {
                lines
                    .append(
                        "Native send audio: provider conference context missing; stream was not registered"
                    )
                return
            }
            // The provider's microphone stream key is separate from the native SDP track ID.
            let stream = try MeetAudioStreamWire.Stream(
                mediaSession: mediaSessionName, conferenceID: conference, streamID: "audio"
            )
            let id = nextStreamRequest()
            lines
                .append("Native dcrpc header: " + client
                    .streamHeaderSource + "; current instance and RTC descriptor")
            let body = try MeetAudioStreamWire.register(
                stream: stream, ssrc: source.ssrc, muted: desiredMuted, requestID: id,
                requestHeader: client.streamControlHeader()
            )
            lines.append("Native send audio: registering the local sender on dcrpc (identifiers withheld)")
            let reply = try await media.exchangeStreamControl(
                body, matches: { MeetAudioStreamWire.matchesRequest($0, requestID: id) }, timeout: .seconds(8)
            )
            try await check()
            lines.append("Native dcrpc registration reply: " + MeetAudioStreamWire.replyDiagnostic(reply))
            lines.append("Native dcrpc registration checks: " + MeetAudioStreamWire.registrationDiagnostic(
                from: reply, stream: stream, ssrc: source.ssrc, muted: desiredMuted, requestID: id
            ))
            let echoed = try MeetAudioStreamWire.confirmRegistration(
                from: reply, stream: stream, ssrc: source.ssrc, muted: desiredMuted, requestID: id
            )
            audioStream = stream
            lines
                .append(
                    "Native send audio: upstream registration accepted; "
                        + (echoed ? "initial microphone state confirmed"
                            : "initial microphone announcement acknowledged")
                )
        } catch {
            guard !closed else { return }
            lines
                .append("Native send audio: registration unconfirmed; " + MeetDMCallTrial
                    .errorDescription(error))
        }
    }

    func setMuted(_ muted: Bool, sequence: UInt64? = nil) async throws -> Bool {
        let next = sequence ?? (muteRevision + 1)
        guard next > muteRevision else { return false }
        muteRevision = next
        let revision = muteRevision
        try await check()
        guard ready, !closed else { throw MeetDeviceSessionError.notJoined }
        guard revision == muteRevision else { return false }
        desiredMuted = muted
        await media.setMuted(muted)
        try await check()
        let local = await media.isMicrophoneMuted
        lines
            .append(local ? "Native microphone: local sender muted" :
                "Native microphone: local sender enabled")
        _ = await streamTask?.value
        try await check()
        guard revision == muteRevision, local == muted, let stream = audioStream else {
            if revision == muteRevision {
                lines.append("Native microphone: provider state unconfirmed")
            }
            return false
        }
        let task = Task { await synchronizeMute(stream: stream, muted: muted, revision: revision) }
        streamTask = task
        let accepted = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if revision == muteRevision {
            streamTask = nil
        }
        return accepted
    }

    private func synchronizeMute(
        stream: MeetAudioStreamWire.Stream,
        muted: Bool,
        revision: UInt64
    ) async -> Bool {
        do {
            try await check()
            guard muteRevision == revision else { return false }
            let id = nextStreamRequest()
            let body = try MeetAudioStreamWire.mute(
                stream: stream, muted: muted, requestID: id, requestHeader: client.streamControlHeader()
            )
            let reply = try await media.exchangeStreamControl(
                body, matches: { MeetAudioStreamWire.matchesRequest($0, requestID: id) }, timeout: .seconds(8)
            )
            try await check()
            guard muteRevision == revision else { return false }
            lines.append("Native dcrpc microphone reply: " + MeetAudioStreamWire.replyDiagnostic(reply))
            let echoed = try MeetAudioStreamWire.confirmMute(
                from: reply, stream: stream, muted: muted, requestID: id
            )
            lines
                .append("Native microphone: provider " + (muted ? "mute" : "unmute")
                    + (echoed ? " confirmed" : " acknowledged; stream state not echoed"))
            return true
        } catch {
            if !closed {
                lines
                    .append("Native microphone: provider state unconfirmed; " + MeetDMCallTrial
                        .errorDescription(error))
            }
            return false
        }
    }

    private func nextStreamRequest() -> UInt64 {
        streamRequestID += 1
        return streamRequestID
    }
}
