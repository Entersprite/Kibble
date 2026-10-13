import Foundation
import LocalBridgeBackend

public extension MeetDMCallTrialModel {
    func setNativeMuted(_ muted: Bool) {
        guard isNativeCallActive, !isEndingNativeCall, !isBusy else { return }
        nativeMicrophoneMuted = muted
        nativeMedia?.setMuted(muted)
        microphoneStatus = muted
            ? "Microphone muted. Updating call status…"
            : "Microphone is on. Updating call status…"
        let revision = UUID()
        microphoneRevision = revision
        microphoneSequence += 1
        let sequence = microphoneSequence
        let scope = nativeRevision
        microphoneTask = Task { [weak self] in
            guard let self, nativeRevision == scope, microphoneRevision == revision else { return }
            var confirmed = false
            do { confirmed = try await trial.setNativeMuted(muted, scope: scope, sequence: sequence)
            } catch {}
            guard nativeRevision == scope, microphoneRevision == revision, isNativeCallActive else { return }
            microphoneStatus = confirmed
                ?
                (muted ? "Microphone muted. Update acknowledged." :
                    "Microphone is on. Update acknowledged.")
                :
                (muted ? "Microphone muted locally. Call status unconfirmed." :
                    "Microphone is on locally. Call status unconfirmed.")
            microphoneTask = nil
            await saveReport()
        }
    }
}
