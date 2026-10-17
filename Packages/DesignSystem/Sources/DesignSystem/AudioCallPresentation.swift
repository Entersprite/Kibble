import ChatKit
import Foundation

enum AudioCallPresentation {
    static func status(for phase: AudioCallPhase) -> String {
        switch phase {
        case .incoming: "Incoming call"
        case .connecting: "Connecting…"
        case .ringing: "Ringing…"
        case .connected: "Connected"
        case .declined: "Decline sent"
        case .failed: "Call failed"
        case .ended: "Call ended"
        case .unknown: "Call unavailable"
        }
    }

    static func canMute(_ phase: AudioCallPhase) -> Bool {
        phase == .ringing || phase == .connected
    }

    static func canHangUp(_ phase: AudioCallPhase) -> Bool {
        phase == .connecting || phase == .ringing || phase == .connected
    }

    /// The halo pulses while the call is waiting for someone to answer.
    static func isWaiting(_ phase: AudioCallPhase) -> Bool {
        phase == .incoming || phase == .connecting || phase == .ringing
    }

    static func failureMessage(for call: AudioCallSnapshot) -> String? {
        if let message = call.failureMessage {
            return message
        }
        return call.phase == .failed ? "The call couldn't be completed. Please try again." : nil
    }

    /// "4:12", or "1:04:12" past an hour.
    static func duration(_ seconds: TimeInterval) -> String {
        let value = Duration.seconds(max(0, Int(seconds)))
        return seconds >= 3600
            ? value.formatted(.time(pattern: .hourMinuteSecond))
            : value.formatted(.time(pattern: .minuteSecond))
    }

    /// Device and sharing messages, shown above the controls only while the
    /// controls they belong to are usable.
    static func notices(
        phase: AudioCallPhase, devices: CallAudioDevices?, camera: CallCameraState?,
        screenSharing: CallScreenShareState?
    ) -> [CallNotice] {
        var notices: [CallNotice] = []
        if !phase.isTerminal, let notice = devices?.notice {
            notices.append(CallNotice(id: "audio", text: notice, kind: .warning))
        }
        guard canMute(phase) else { return notices }
        if let notice = camera?.notice {
            notices.append(CallNotice(id: "camera", text: notice, kind: .warning))
        }
        if screenSharing?.phase == .preparing {
            notices.append(CallNotice(
                id: "share-picker", text: "Choose a window or display to share.", kind: .info
            ))
        }
        if let notice = screenSharing?.notice {
            notices.append(CallNotice(id: "share", text: notice, kind: .warning))
        }
        return notices
    }
}

/// Collection feedback belongs to presentation; diagnostics contents stay in
/// the host and never enter the call view's state.
enum AudioCallCopyState {
    case idle, collecting, copied, unavailable

    var title: String {
        switch self {
        case .idle: "Copy Diagnostics"
        case .collecting: "Collecting…"
        case .copied: "Copied"
        case .unavailable: "Unavailable"
        }
    }

    /// What a live call shows above its controls after the menu item is chosen.
    var notice: CallNotice? {
        switch self {
        case .idle: nil
        case .collecting: CallNotice(id: "diagnostics", text: "Collecting diagnostics…", kind: .progress)
        case .copied: CallNotice(id: "diagnostics", text: "Diagnostics copied", kind: .success)
        case .unavailable: CallNotice(id: "diagnostics", text: "Diagnostics unavailable", kind: .warning)
        }
    }
}
