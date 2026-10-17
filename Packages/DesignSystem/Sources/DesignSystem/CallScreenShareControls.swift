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

struct CallScreenShareControls: View {
    let state: CallScreenShareState
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(
                title,
                systemImage: state.phase == .idle ? "rectangle.on.rectangle" : "stop.circle.fill",
                action: toggle
            )
            .disabled(state.phase == .stopping)
            if state.phase == .preparing {
                Text("Choose a window or display in the system picker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = state.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
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
