@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

extension NativeCallMedia {
    static func configureAudioCodecs(
        _ connection: LKRTCPeerConnection, factory: LKRTCPeerConnectionFactory
    ) throws {
        // Meet's browser uses setCodecPreferences with audio/opus and audio/red.
        // Apply that limit to the actual peer before generating or installing
        // its offer; do not advertise the SDK's legacy telephony codecs.
        let codecs = factory.rtpReceiverCapabilities(forKind: kLKRTCMediaStreamTrackKindAudio).codecs
            .filter { codec in
                ["audio/opus", "audio/red"].contains(codec.mimeType.lowercased())
                    && codec.clockRate?.intValue == 48000 && codec.numChannels?.intValue == 2
            }
        guard codecs.contains(where: { $0.mimeType.lowercased() == "audio/opus" }),
              connection.transceivers.count == 1,
              let transceiver = connection.transceivers.first else {
            throw CallMediaError.negotiationFailed
        }
        do {
            // The empty error argument selects the throwing API; the one-
            // argument overload is deprecated and discards native failures.
            try transceiver.setCodecPreferences(codecs, error: ())
        } catch {
            throw CallMediaError.negotiationFailed
        }
    }
}
