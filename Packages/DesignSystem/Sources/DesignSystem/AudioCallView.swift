import ChatKit
import SwiftUI

/// Call controls are callbacks so the same window can serve any call service.
@MainActor
public struct AudioCallActions {
    public var accept: () -> Void
    public var decline: () -> Void
    public var toggleMute: () -> Void
    public var hangUp: () -> Void

    public init(
        accept: @escaping () -> Void,
        decline: @escaping () -> Void,
        toggleMute: @escaping () -> Void,
        hangUp: @escaping () -> Void
    ) {
        self.accept = accept
        self.decline = decline
        self.toggleMute = toggleMute
        self.hangUp = hangUp
    }
}

/// One small window for outgoing and incoming audio calls.
public struct AudioCallView: View {
    private let call: AudioCallSnapshot
    private let actions: AudioCallActions

    public init(call: AudioCallSnapshot, actions: AudioCallActions) {
        self.call = call
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(call.recipient.displayName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(AudioCallPresentation.status(for: call.phase))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                if let message = call.failureMessage ?? (call.phase == .failed
                    ? "The call couldn't be completed. Please try again." : nil) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            HStack(spacing: 16) {
                if call.phase == .incoming {
                    Button("Decline", systemImage: "phone.down.fill", action: actions.decline)
                        .tint(.red)
                    Button("Accept", systemImage: "phone.fill", action: actions.accept)
                        .tint(.green)
                } else {
                    Button(
                        call.isMuted ? "Unmute" : "Mute",
                        systemImage: call.isMuted ? "mic.slash.fill" : "mic.fill",
                        action: actions.toggleMute
                    )
                    .disabled(!AudioCallPresentation.canMute(call.phase))
                    Button("Hang Up", systemImage: "phone.down.fill", action: actions.hangUp)
                        .tint(.red)
                        .disabled(!AudioCallPresentation.canHangUp(call.phase))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 380)
        .frame(minHeight: 300)
    }
}

enum AudioCallPresentation {
    static func status(for phase: AudioCallPhase) -> String {
        switch phase {
        case .incoming: "Incoming audio call"
        case .connecting: "Connecting…"
        case .ringing: "Ringing…"
        case .connected: "Connected"
        case .declined: "Decline sent"
        case .failed: "Call failed"
        case .ended: "Ended"
        case .unknown: "Call unavailable"
        }
    }

    static func canMute(_ phase: AudioCallPhase) -> Bool {
        phase == .ringing || phase == .connected
    }

    static func canHangUp(_ phase: AudioCallPhase) -> Bool {
        phase == .connecting || phase == .ringing || phase == .connected
    }
}
