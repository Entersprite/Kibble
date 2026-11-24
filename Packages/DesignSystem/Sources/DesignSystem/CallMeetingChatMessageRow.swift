import ChatKit
import SwiftUI

struct CallMeetingChatMessageRow: View {
    let message: CallMeetingMessage
    let showsPinAction: Bool
    let changePin: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.sender)
                    if message.isPinned == true {
                        Label("Pinned", systemImage: "pin.fill")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled)
            }
            if message.canChangePin == true, showsPinAction {
                Spacer(minLength: 0)
                let pinned = message.isPinned == true
                let title = pinned ? "Unpin Message" : "Pin Message"
                Button(title, systemImage: pinned ? "pin.slash" : "pin", action: changePin)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help(title)
            }
        }
    }
}
