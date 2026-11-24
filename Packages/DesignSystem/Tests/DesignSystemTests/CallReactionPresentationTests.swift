import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallReactionPresentationTests {
    @Test func aBurstKeepsMultipleSendersAndOldSnapshotsDoNotReplayExpiredReactions() {
        let values = sample()
        let firstBatch = Array(values.prefix(2))
        var presentation = CallReactionPresentation()
        presentation.receive(firstBatch)
        #expect(presentation.visible == firstBatch)

        presentation.dismiss(values[0].id)
        presentation.receive(firstBatch)
        #expect(presentation.visible == [values[1]])

        presentation.receive(values)
        #expect(presentation.visible == Array(values.suffix(3)))
        presentation.dismiss(values[1].id)
        #expect(presentation.visible == Array(values.suffix(3)))

        presentation.receive([])
        #expect(presentation.visible.isEmpty)
        presentation.receive(values)
        #expect(presentation.visible.isEmpty)
    }

    @Test(arguments: [false, true])
    func aReactionBurstRendersInTheCompactCallFrame(captions: Bool) async throws {
        let url = try #require(URL(string: "https://meet.example.test/room"))
        let target = ConversationCallTarget(meetingURL: url, displayName: "Design Review")
        let call = AudioCallSession(ConversationCallSnapshot(id: UUID(), target: target, phase: .connected))
        var state = CallActivitiesState()
        state.reactions = Array(sample().prefix(3))
        if captions {
            state.captions = CallCaptionState(
                spokenLanguage: "en-US", displayLanguage: "fr-FR",
                segments: [CallCaptionSegment(
                    id: UUID(), speaker: "Taylor",
                    text: "Bonjour. Voici le dernier plan pour la revue de conception."
                )]
            )
        }
        var actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
        actions.activities = CallActivitiesScene(state: state, perform: { _ in })
        let view = AudioCallView(call: call, actions: actions)
            .frame(width: CallLayout.compact.width, height: CallLayout.compact.height)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        #expect(host.frame.size == CallLayout.compact)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_REACTION_RENDER_DIR"] {
            let data = try #require(image.representation(using: .png, properties: [:]))
            let name = captions ? "captions.png" : "reaction-burst.png"
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
    }

    private func sample() -> [CallMeetingReaction] {
        zip(["Taylor", "Casey", "Jordan", "Jamie", "Sam"], ["👍", "👏", "🎉", "😂", "❤️"]).map {
            CallMeetingReaction(id: UUID(), sender: $0.0, emoji: $0.1)
        }
    }
}
