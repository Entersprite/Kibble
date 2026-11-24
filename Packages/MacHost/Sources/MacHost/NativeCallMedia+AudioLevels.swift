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

    func localAudioActivity() async -> CallLocalAudioActivity? {
        guard !Task.isCancelled, !isPresentation, isConnected, !isMicrophoneMuted,
              let peer, let sender = audioSender, let track = sender.track else { return nil }
        let scope = generation
        let trackID = track.trackId
        let waiter = NativeMediaStatisticsWaiter<CallLocalAudioActivity>()
        let sample = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                guard waiter.isPending else { return }
                waiter.armTimeout(.milliseconds(750))
                peer.statistics(for: sender) { report in
                    guard waiter.isPending else { return }
                    waiter.finish(Self.localAudioActivity(report, trackID: trackID))
                }
            }
        } onCancel: {
            waiter.finish(nil)
        }
        guard !Task.isCancelled, generation == scope, self.peer === peer, isConnected,
              !isMicrophoneMuted, audioSender?.track?.trackId == trackID else { return nil }
        return sample
    }

    private nonisolated static func localAudioActivity(
        _ report: LKRTCStatisticsReport, trackID: String
    ) -> CallLocalAudioActivity? {
        guard report.statistics.count <= NativeAudioStatistics.maximumRecords else { return nil }
        let source = report.statistics.values.filter {
            $0.type == "media-source" && $0.values["kind"] as? String == "audio"
                && $0.values["trackIdentifier"] as? String == trackID
        }
        guard source.count == 1, let record = source.first,
              let level = (record.values["audioLevel"] as? NSNumber)?.doubleValue,
              level.isFinite, (0 ... 1).contains(level), record.timestamp_us.isFinite
        else { return nil }
        return CallLocalAudioActivity(level: level, timestamp: record.timestamp_us)
    }
}
