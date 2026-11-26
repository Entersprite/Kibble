import ChatKit
import SwiftUI

struct CallWaitingPeopleSection: View {
    let participants: [CallWaitingParticipant]
    let busy: Bool
    let canRespondInBulk: Bool
    let perform: (CallActivity) -> Void
    let confirmDenial: ([UUID]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting to Join").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(participants) { participant in
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(participant.name).lineLimit(1)
                        Text(participant.isInWaitingRoom ? "In the waiting room" : "Asking to join")
                            .font(.caption).foregroundStyle(.secondary)
                        if let warning = participant.warning {
                            Label {
                                Text(warningText(warning))
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if participant.canDeny {
                        Button("Deny") { respond(participant, admit: false) }
                            .accessibilityLabel("Deny \(participant.name)")
                    }
                    Button("Admit") { respond(participant, admit: true) }
                        .accessibilityLabel("Admit \(participant.name)")
                }
            }
            if canRespondInBulk, participants.count > 1 {
                bulkButtons
            }
            Divider()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .controlSize(.small)
        .disabled(busy)
    }

    private var bulkButtons: some View {
        HStack {
            Spacer()
            let deny = participants.filter(\.canDeny).map(\.id)
            if deny.count > 1 {
                Button("Deny All…") { confirmDenial(deny) }
            }
            Button("Admit All") {
                var activity = CallActivity("respondToAdmissions")
                activity.participantIDs = participants.map(\.id)
                perform(activity)
            }
        }
    }

    private func respond(_ participant: CallWaitingParticipant, admit: Bool) {
        perform(CallActivity("respondToAdmission", resourceID: participant.id, enabled: admit))
    }

    private func warningText(_ warning: CallWaitingParticipant.Warning) -> LocalizedStringKey {
        switch warning {
        case .suspiciousUser: "Suspicious activity"
        case .suspectedBot: "May be a bot"
        case .potentialRisk: "Potential risk"
        }
    }
}
