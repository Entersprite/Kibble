import ChatKit
import SwiftUI

enum MessageDeliveryPresentation {
    static func label(_ status: MessageDeliveryStatus) -> String {
        switch status {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .failed: "Not sent"
        default: "Delivery unconfirmed"
        }
    }

    static func offersCheck(_ status: MessageDeliveryStatus) -> Bool {
        status != .sent && status != .failed
    }
}

struct MessageDeliveryLabel: View {
    let status: MessageDeliveryStatus
    let checking: Bool
    var check: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Text(MessageDeliveryPresentation.label(status))
                .foregroundStyle(status == .failed ? .red : .secondary)
            if MessageDeliveryPresentation.offersCheck(status), let check {
                Button(checking ? "Checking…" : "Check Status", action: check)
                    .deliveryCheckStyle()
                    .disabled(checking)
            }
        }
        .font(.caption2)
        .help("Checking delivery status does not send the message again.")
    }
}

private extension View {
    /// A link button on the Mac, the system's own look for an inline action
    /// in text; tinted plain text where there is none.
    @ViewBuilder func deliveryCheckStyle() -> some View {
        #if os(macOS)
            buttonStyle(.link)
        #else
            buttonStyle(.plain).foregroundStyle(.tint)
        #endif
    }
}
