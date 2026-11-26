import ChatKit
import SwiftUI

extension MessageBubble {
    @ViewBuilder var body: some View {
        if let activity = message.activity, !message.isDeleted {
            MessageActivityRow(
                activity: activity,
                sender: message.sender == state.me ? "You" : Display.name(
                    of: message.sender,
                    in: state.directory
                )
            )
            .accessibilityValue(Display.timestamp(of: message.createdAt))
        } else {
            ordinaryRow
        }
    }
}

struct MessageActivityRow: View {
    let activity: MessageActivity
    let sender: String

    var title: String {
        switch activity {
        case .pinnedMessage: "\(sender) pinned a message"
        case .pinnedResource: "\(sender) pinned a resource"
        case .unknown: "Conversation activity"
        }
    }

    /// The pin for a pin, and a neutral mark for activity this build cannot name.
    var symbol: String {
        switch activity {
        case .pinnedMessage, .pinnedResource: PinStyle.symbol
        case .unknown: "info.circle"
        }
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }
}
