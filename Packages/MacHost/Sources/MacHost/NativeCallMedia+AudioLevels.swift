import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

public extension NativeCallMedia {
    func remoteAudioLevels() -> [CallAudioSourceLevel] {
        guard isConnected, let peer else { return [] }
        return peer.receivers.filter { $0.track?.kind == kLKRTCMediaStreamTrackKindAudio }
            .prefix(8).flatMap { receiver in
                receiver.sources.prefix(256).compactMap { source in
                    guard let level = source.audioLevel?.doubleValue, level.isFinite,
                          (0 ... 1).contains(level), source.timestampUs.isFinite else { return nil }
                    return CallAudioSourceLevel(
                        source: source.sourceId,
                        level: level,
                        timestamp: source.timestampUs
                    )
                }
            }
    }
}
