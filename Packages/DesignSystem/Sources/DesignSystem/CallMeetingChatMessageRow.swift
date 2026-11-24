import ChatKit
import SwiftUI

/// One of the meeting's own messages: who sent it, a pin when it is pinned,
/// and the pin control only for someone who may change it.
struct CallMeetingChatMessageRow: View {
    let message: CallMeetingMessage
    let showsPinAction: Bool
    var isBusy = false
    let changePin: () -> Void

    var body: some View {
        let pinned = message.isPinned == true
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Pinned")
                    }
                    Text(message.sender)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if message.canChangePin == true, showsPinAction {
                let title = pinned ? "Unpin Message" : "Pin Message"
                Button(title, systemImage: pinned ? "pin.slash" : "pin", action: changePin)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                    .help(title)
            }
        }
    }
}
