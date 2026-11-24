import ChatKit
import SwiftUI

struct CallAgendaGuestSection: View {
    let guests: [CallAgendaGuest]
    var busy = false
    var openChat: ((UUID) -> Void)?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            Text("Also Invited").font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(guests) { guest in
                HStack(spacing: 6) {
                    guestDetails(guest)
                    Spacer(minLength: 0)
                    if guest.chatAddress != nil, let openChat {
                        Button("Chat with \(guest.displayName)", systemImage: "bubble.left") {
                            openChat(guest.id)
                        }
                        .labelStyle(.iconOnly)
                        .help("Chat with \(guest.displayName)")
                        .disabled(busy)
                    }
                }
            }
        }
        .padding(8)
    }

    private func guestDetails(_ guest: CallAgendaGuest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(guest.displayName).font(.callout).lineLimit(2)
            HStack(spacing: 6) {
                if let status = status(for: guest.response) {
                    Text(status)
                }
                if guest.isOptional {
                    Text("Optional")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func status(for response: String?) -> LocalizedStringKey? {
        switch response {
        case "accepted": "Accepted"
        case "tentative": "Maybe"
        case "declined": "Declined"
        case "needsAction": "Awaiting Response"
        default: nil
        }
    }
}
