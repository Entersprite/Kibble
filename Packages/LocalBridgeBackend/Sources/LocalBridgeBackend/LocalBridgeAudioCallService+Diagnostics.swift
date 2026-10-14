import ChatKit
import Foundation

public extension LocalBridgeAudioCallService {
    /// Owner-requested diagnostics for exactly the current call. The host's
    /// media report contains fixed aggregate labels, never signaling data.
    func diagnosticReport(callID: UUID) async -> String? {
        guard snapshot?.id == callID, !isStopping, !Task.isCancelled else { return nil }
        let session = sessionScope
        let call = callScope
        let engine = media
        let native = await trial.diagnosticSnapshot()
        guard diagnosticMatches(callID, session: session, call: call, engine: engine),
              let native else { return nil }
        let audio = await engine?.diagnosticReport() ?? []
        guard diagnosticMatches(callID, session: session, call: call, engine: engine),
              let current = snapshot else { return nil }
        let header = [
            "Kibble audio call diagnostics",
            "Call phase: \(Self.diagnosticPhase(current.phase))",
            "Call direction: \(Self.diagnosticDirection(current.direction))",
            "Call mute requested: \(current.isMuted)",
            "Native microphone muted: \(engine.map { String($0.isMicrophoneMuted) } ?? "unavailable")"
        ]
        return (header + [native] + audio).joined(separator: "\n")
    }
}

private extension LocalBridgeAudioCallService {
    func diagnosticMatches(
        _ id: UUID, session: UUID, call: UUID, engine: (any CallMediaEngine)?
    ) -> Bool {
        !Task.isCancelled && !isStopping && snapshot?.id == id
            && sessionScope == session && callScope == call && media === engine
    }

    static func diagnosticPhase(_ phase: AudioCallPhase) -> String {
        switch phase {
        case .incoming: "incoming"
        case .connecting: "connecting"
        case .ringing: "ringing"
        case .connected: "connected"
        case .failed: "failed"
        case .ended: "ended"
        case .declined: "declined"
        case .unknown: "unknown"
        }
    }

    static func diagnosticDirection(_ direction: AudioCallDirection) -> String {
        switch direction {
        case .incoming: "incoming"
        case .outgoing: "outgoing"
        case .unknown: "unknown"
        }
    }
}
