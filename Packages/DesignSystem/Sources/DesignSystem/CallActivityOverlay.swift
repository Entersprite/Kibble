import ChatKit
import SwiftUI

struct CallActivityOverlay: ViewModifier {
    let callID: UUID
    let state: CallActivitiesState?

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            CallReactionStack(reactions: state?.reactions ?? [])
                .id(callID)
                .allowsHitTesting(false)
        }
    }
}

private struct CallReactionStack: View {
    let reactions: [CallMeetingReaction]
    @State private var presentation = CallReactionPresentation()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(presentation.visible) { reaction in
                Text(reaction.emoji + " " + reaction.sender)
                    .font(.title3)
                    .lineLimit(1)
                    .padding(12)
                    .background(.ultraThinMaterial, in: .capsule)
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        presentation.dismiss(reaction.id)
                    }
            }
        }
        .padding(.top, 40)
        .padding(.horizontal, 16)
        .onChange(of: reactions.last?.id, initial: true) { _, _ in
            presentation.receive(reactions)
        }
    }
}

struct CallReactionPresentation {
    private(set) var visible: [CallMeetingReaction] = []
    private var lastReceived: UUID?

    mutating func receive(_ reactions: [CallMeetingReaction]) {
        guard let latest = reactions.last?.id else {
            visible.removeAll()
            return
        }
        guard lastReceived != latest else { return }
        let newReactions = lastReceived.flatMap { id in reactions.lastIndex { $0.id == id } }
            .map { reactions.dropFirst($0 + 1) } ?? reactions[...]
        visible = Array((visible + newReactions).suffix(3))
        lastReceived = latest
    }

    mutating func dismiss(_ reaction: UUID) {
        visible.removeAll { $0.id == reaction }
    }
}

struct CallHandLoweredNotice: View {
    private static let notice = CallNotice(id: "handLowered", text: "Your hand was lowered.", kind: .info)
    let event: UUID?
    @State private var presentation: CallHandLoweringPresentation

    init(event: UUID?) {
        self.event = event
        _presentation = State(initialValue: CallHandLoweringPresentation(previous: event))
    }

    var body: some View {
        Group {
            if presentation.visible != nil {
                CallNoticeView(notice: Self.notice)
            }
        }
        .onChange(of: event) { _, newest in
            if presentation.receive(newest) {
                AccessibilityNotification.Announcement(Self.notice.text).post()
            }
        }
        .task(id: presentation.visible) {
            guard let event = presentation.visible else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            presentation.dismiss(event)
        }
    }
}

struct CallHandLoweringPresentation {
    private var previous: UUID?
    private(set) var visible: UUID?

    init(previous: UUID?) {
        self.previous = previous
    }

    mutating func receive(_ event: UUID?) -> Bool {
        guard let event, event != previous else { return false }
        previous = event
        visible = event
        return true
    }

    mutating func dismiss(_ event: UUID) {
        if visible == event {
            visible = nil
        }
    }
}

struct CallHandFeedback: View {
    var scene: CallActivitiesScene?
    let participants: [CallParticipantDevice]?
    var gestureProgress: Double?
    @Binding var showsPeople: Bool

    var body: some View {
        CallHandLoweredNotice(event: scene?.state.ownHandLowered)
        if let gestureProgress {
            ProgressView("Hand detected", value: gestureProgress)
                .font(.callout)
                .frame(maxWidth: 160)
                .padding(10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
        if let scene, let prompt = scene.state.automaticHandLowering,
           scene.state.availableActions.contains("keepHandRaised") {
            CallAutomaticHandPrompt(prompt: prompt, perform: scene.perform).id(prompt.id)
        }
        CallRaisedHandsNotice(
            participants: participants,
            canOpenQueue: scene?.state.availableActions.contains("lowerParticipantHand") == true,
            showsPeople: $showsPeople
        )
    }
}

struct CallHandControls: View {
    let actions: AudioCallActions

    var body: some View {
        if let toggle = actions.toggleHandRaised {
            Button(CallMenu.handTitle(actions.handRaised == true), systemImage: "hand.raised", action: toggle)
                .disabled(actions.isUpdatingHand)
        }
        if let gesture = actions.handGesture {
            Toggle(
                "Raise Hand with a Gesture",
                isOn: Binding(get: { gesture.isEnabled }, set: gesture.setEnabled)
            )
        }
    }
}

struct CallAutomaticHandPrompt: View {
    let prompt: CallAutomaticHandLowering
    let perform: (CallActivity) async throws -> Void
    @State private var request: Task<Void, Never>?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(failed ? "Couldn’t keep your hand raised. Try again." : message(at: context.date))
                    .monospacedDigit()
            }
            Button("Keep it raised") {
                guard request == nil else { return }
                request = Task {
                    defer { request = nil }
                    do {
                        try await perform(CallActivity("keepHandRaised", resourceID: prompt.id))
                    } catch {
                        if !Task.isCancelled {
                            failed = true
                        }
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(request != nil)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement("Your hand will be lowered soon. You can keep it raised.")
                .post()
        }
        .onDisappear { request?.cancel() }
    }

    private func message(at time: Date) -> String {
        let seconds = prompt.deadline.timeIntervalSince(time)
        guard seconds.isFinite else { return "Your hand will be lowered soon." }
        let remaining = Int(min(10, max(0, seconds.rounded(.up))))
        return "Lowering your hand in \(remaining) s"
    }
}
