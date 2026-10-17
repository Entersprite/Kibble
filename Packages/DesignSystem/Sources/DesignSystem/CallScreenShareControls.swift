import SwiftUI

/// Local presentation state supplied by the host. Content titles and capture
/// identifiers are intentionally absent from the call surface.
public struct CallScreenShareState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, preparing, sharing, stopping }
    public var phase: Phase
    public var notice: String?

    public init(phase: Phase = .idle, notice: String? = nil) {
        self.phase = phase; self.notice = notice
    }
}

/// Starts sharing through the system picker, and stops or cancels it. Lit
/// in the accent color from the moment the picker opens until sharing ends.
struct CallScreenShareButton: View {
    let state: CallScreenShareState
    let toggle: () -> Void

    var body: some View {
        CallRoundButton(
            title: title,
            symbol: "rectangle.on.rectangle",
            tone: state.phase == .idle ? .plain : .active,
            action: toggle
        )
        .disabled(state.phase == .stopping)
    }

    private var title: String {
        switch state.phase {
        case .idle: "Share Screen…"
        case .preparing: "Cancel Sharing"
        case .sharing: "Stop Sharing"
        case .stopping: "Stopping Sharing…"
        }
    }
}
