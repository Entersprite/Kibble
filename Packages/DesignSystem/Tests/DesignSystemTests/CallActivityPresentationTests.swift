import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallActivityPresentationTests {
    @Test(arguments: ["Meeting", "Chat", "Polls", "Q&A", "Rooms"])
    func activityTabsRenderOffscreen(_ tab: String) async throws {
        let state = sampleState()
        let view = CallActivitiesView(
            scene: CallActivitiesScene(state: state, perform: { _ in }),
            initialTab: tab
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        #expect(host.frame.width == 560 && host.frame.height == 560)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_ACTIVITY_RENDERS"] {
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(tab.replacingOccurrences(
                    of: "&",
                    with: "and"
                ) + ".png"))
        }
    }

    private func sampleState() -> CallActivitiesState {
        var state = CallActivitiesState()
        state.availableActions = [
            "react",
            "chat",
            "recording",
            "transcription",
            "notes",
            "attendance",
            "createPoll",
            "votePoll",
            "closePoll", "sharePollResults",
            "askQuestion",
            "voteQuestion",
            "answerQuestion",
            "createRooms",
            "openRooms",
            "closeRooms",
            "assignRoom"
        ]
        state.artifacts = [
            CallArtifact(kind: "recording", phase: "active"),
            CallArtifact(kind: "transcription", phase: "stopped"),
            CallArtifact(
                kind: "notes",
                phase: "stopped"
            )
        ]
        state.messages = [CallMeetingMessage(id: UUID(), sender: "Taylor", text: "Meeting notes are ready.")]
        state.polls = [CallPoll(
            id: UUID(),
            question: "Which option?",
            options: ["One", "Two"],
            votes: [2, 3],
            isOpen: true, resultsVisible: false
        )]
        state.allowsAnonymousQuestions = true
        state.questions = [CallQuestion(id: UUID(), text: "When do we start?", votes: 3)]
        state.rooms = [CallBreakoutRoom(
            id: UUID(),
            name: "Design",
            isOpen: true,
            joinURL: URL(string: "https://meet.example.test/room")
        )]
        state.people = [CallBreakoutPerson(id: UUID(), name: "Taylor")]
        return state
    }
}
