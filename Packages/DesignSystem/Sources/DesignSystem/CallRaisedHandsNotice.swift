import ChatKit
import SwiftUI

struct CallRaisedHandsNotice: View {
    let participants: [CallParticipantDevice]?
    let canOpenQueue: Bool
    @Binding var showsPeople: Bool
    @State private var presentation = CallRaisedHandsPresentation()

    var body: some View {
        Group {
            if let message = presentation.message {
                CallRaisedHandsBanner(
                    message: message, openQueue: canOpenQueue ? {
                        showsPeople = true
                        presentation.dismiss()
                    } : nil,
                    dismiss: { presentation.dismiss() }
                )
            }
        }
        .onChange(of: snapshot, initial: true) { _, snapshot in
            if presentation.receive(snapshot.raised, queueOpen: snapshot.queueOpen),
               let message = presentation.message {
                AccessibilityNotification.Announcement(message).post()
            }
        }
        .task(id: presentation.event) {
            guard let event = presentation.event else { return }
            try? await Task.sleep(for: .milliseconds(7500))
            guard !Task.isCancelled else { return }
            presentation.dismiss(event)
        }
    }

    private var snapshot: Snapshot {
        Snapshot(
            raised: CallRaisedHandsPresentation.knownHands(in: participants),
            queueOpen: showsPeople
        )
    }

    private struct Snapshot: Equatable {
        let raised: [CallRaisedHandsPresentation.Hand]?
        let queueOpen: Bool
    }
}

struct CallRaisedHandsBanner: View {
    let message: String
    var openQueue: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                CallRaisedHandGlyph().accessibilityHidden(true)
                Text(message).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Dismiss")
            }
            if let openQueue {
                Button("Show Raised Hands", action: openQueue)
                    .buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 320)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct CallRaisedHandsPresentation {
    struct Hand: Equatable {
        let id: UUID
        let name: String
    }

    private var previous: Set<UUID>?
    private var visible: [Hand] = []
    private(set) var event: UUID?

    static func knownHands(in participants: [CallParticipantDevice]?) -> [Hand]? {
        guard let participants else { return nil }
        let remote = participants.filter { !$0.isLocal && !$0.isPresentation }
        guard remote.allSatisfy({ $0.handRaised != nil }), let roster = CallRoster.entries(remote)
        else { return nil }
        return CallRoster.raisedHands(roster).map { Hand(id: $0.id, name: $0.name) }
    }

    var message: String? {
        switch visible.count {
        case 0: nil
        case 1: "\(visible[0].name) raised their hand"
        case 2: "\(visible[0].name) and \(visible[1].name) raised their hands"
        default: "\(visible[0].name), \(visible[1].name), and \(visible.count - 2) more raised their hands"
        }
    }

    /// A new window or a missing roster has no observation baseline. An
    /// already open queue remains the presentation for those arrivals.
    mutating func receive(_ raised: [Hand]?, queueOpen: Bool) -> Bool {
        let observed = previous
        previous = raised.map { Set($0.map(\.id)) }
        guard let raised, let observed, !queueOpen else {
            dismiss()
            return false
        }
        let retained = Set(visible.map(\.id))
        visible = raised.filter { retained.contains($0.id) || !observed.contains($0.id) }
        if visible.isEmpty {
            dismiss()
        }
        guard visible.contains(where: { !observed.contains($0.id) }) else { return false }
        event = UUID()
        return true
    }

    mutating func dismiss(_ expected: UUID? = nil) {
        guard expected == nil || event == expected else { return }
        visible = []
        event = nil
    }
}
