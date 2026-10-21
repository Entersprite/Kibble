import ChatKit
import SwiftUI

/// Transcript history only. The incoming-call banner owns live call controls.
struct CallMessageCard: View {
    let status: MessageCallStatus

    private var title: String {
        switch status {
        case .started: "Call started"
        case .missed: "Call missed"
        case .ended: "Call ended"
        case .unknown: "Call activity"
        }
    }

    private var tint: Color {
        switch status {
        case .started: .accentColor
        case .missed: .red
        case .ended, .unknown: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status == .missed ? "video.slash.fill" : "video.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(status == .missed ? .red : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
