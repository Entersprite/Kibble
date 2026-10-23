import Foundation
import GChatBridgeCore

/// The other person's microphone, from the DOWN stream search (findings §66.40
/// for the mute field, §66.52 for the search). The video poll already searches
/// every two seconds; when the camera stream could not be registered, a poll of
/// the same period searches for audio alone, so a voice call still has it.
extension NativeMeetCallSession {
    func recordRemoteAudio(_ reply: Data, context: MeetVideoStreamWire.Context, requestID: UInt64) async {
        // A malformed or ambiguous reply is unknown, never muted.
        let muted = try? MeetVideoStreamWire.remoteAudioMuted(
            from: reply,
            context: context,
            requestID: requestID
        )
        await publishRemoteAudio(muted)
    }

    func publishRemoteAudio(_ muted: Bool?) async {
        guard !closed, muted != remoteAudioMuted else { return }
        remoteAudioMuted = muted
        lines.append("Native audio: remote microphone " + (muted.map { $0 ? "muted" : "on" } ?? "unknown"))
        await receiveRemoteMuted?(muted)
    }

    func startRemoteAudioPoll() async {
        guard !closed, videoPoll == nil, audioStream != nil,
              let conference = await device.conferenceID,
              let context = try? MeetVideoStreamWire.Context(
                  mediaSession: mediaSessionName,
                  conferenceID: conference
              ) else { return }
        audioSearchContext = context
        videoPoll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await refreshRemoteAudio()
            }
        }
    }

    func refreshRemoteAudio() async {
        guard ready, !closed, !isSuspended, disconnectedAt == nil, videoContext == nil,
              let context = audioSearchContext else { return }
        do {
            try await check()
            let id = nextStreamRequest()
            let request = try MeetVideoStreamWire.search(
                context: context,
                requestID: id,
                header: client.streamControlHeader()
            )
            let reply = try await media.exchangeStreamControl(
                request,
                matches: { MeetAudioStreamWire.matchesRequest($0, requestID: id) },
                timeout: .seconds(8)
            )
            try await check()
            await recordRemoteAudio(reply, context: context, requestID: id)
        } catch {
            guard !closed, !Task.isCancelled else { return }
            await publishRemoteAudio(nil)
        }
    }
}
