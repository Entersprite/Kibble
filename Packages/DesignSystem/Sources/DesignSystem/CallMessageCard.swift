import ChatKit
import SwiftUI

/// Transcript history only. The incoming-call banner owns live call controls.
///
/// Every card is the same size, whatever it says: the glyph sits in a fixed
/// column, and the words take the width of the longest title. A card sized
/// to its own words drew Call missed wider than Call ended (owner's
/// screenshot).
struct CallMessageCard: View {
    let status: MessageCallStatus

    static let statuses: [MessageCallStatus] = [.started, .missed, .ended, .unknown("")]
    static let glyphSize = CGSize(width: 26, height: 22)

    private var title: String {
        Self.title(of: status)
    }

    static func title(of status: MessageCallStatus) -> String {
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
                .frame(width: Self.glyphSize.width, height: Self.glyphSize.height)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                // Every title, unseen, so the widest sets the card's width.
                ForEach(Self.statuses, id: \.self) { other in
                    Text(Self.title(of: other)).hidden()
                }
                Text(title)
                    .foregroundStyle(status == .missed ? .red : .primary)
            }
            .font(.callout.weight(.medium))
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
