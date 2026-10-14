import ChatKit
import SwiftUI

/// Call controls are callbacks so the same window can serve any call service.
@MainActor
public struct AudioCallActions {
    public var accept: () -> Void
    public var decline: () -> Void
    public var toggleMute: () -> Void
    public var hangUp: () -> Void
    /// Optional host-owned collection and copying; false reports unavailable.
    public var copyDiagnostics: (() async -> Bool)?

    public init(
        accept: @escaping () -> Void,
        decline: @escaping () -> Void,
        toggleMute: @escaping () -> Void,
        hangUp: @escaping () -> Void,
        copyDiagnostics: (() async -> Bool)? = nil
    ) {
        self.accept = accept
        self.decline = decline
        self.toggleMute = toggleMute
        self.hangUp = hangUp
        self.copyDiagnostics = copyDiagnostics
    }
}

/// One small window for outgoing and incoming audio calls.
public struct AudioCallView: View {
    private let call: AudioCallSnapshot
    private let actions: AudioCallActions
    @State private var copyState = AudioCallCopyState.idle
    @State private var requestedCall: UUID?
    @State private var copyRequest = 0

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
        .overlay(alignment: .bottom) {
            if let copyDiagnostics = actions.copyDiagnostics {
                Button(copyState.title, systemImage: "doc.on.clipboard") {
                    requestedCall = call.id
                    copyState = .collecting
                    copyRequest += 1
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(copyState == .collecting)
                .accessibilityLabel("Copy Diagnostics")
                .help("Copy call diagnostics")
                .padding(.bottom, 10)
                .task(id: CopyRequest(call: call.id, sequence: copyRequest)) {
                    guard requestedCall == call.id, copyState == .collecting else { return }
                    let copied = await copyDiagnostics()
                    guard !Task.isCancelled, requestedCall == call.id else { return }
                    copyState = copied ? .copied : .unavailable
                }
            }
        }
        .onChange(of: call.id) {
            requestedCall = nil
            copyState = .idle
        }
    }

    private struct CopyRequest: Hashable {
        let call: UUID
        let sequence: Int
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
}
