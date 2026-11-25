import Foundation
import Testing
@testable import ChatKit

struct CallActivityContractTests {
    @Test func missingOptionalActivityStateIsUnknownAndFutureActionNamesRoundTrip() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let state = try decoder.decode(CallActivitiesState.self, from: Data("{}".utf8))
        #expect(state.availableActions.isEmpty && state.people.isEmpty && state.artifacts.isEmpty)
        #expect(state.artifactFiles.isEmpty)
        #expect(state.agendaAttachments == nil)
        #expect(state.agendaGuests == nil)
        #expect(state.waitingParticipants.isEmpty)
        #expect(state.ownHandLowered == nil)
        #expect(state.breakoutClosing == nil && state.breakoutClosed == nil)
        #expect(state.attendanceReportEnabled == nil && state.captions == nil && state
            .captionLanguages == nil)
        let action = try decoder.decode(CallActivity.self, from: Data(#"{"action":"futureActivity"}"#.utf8))
        #expect(action.action == "futureActivity" && action.participantIDs.isEmpty && action.enabled)
        #expect(try decoder.decode(CallActivity.self, from: encoder.encode(action)) == action)
        #expect(throws: DecodingError.self) {
            try decoder.decode(CallActivitiesState.self, from: Data(#"{"availableActions":false}"#.utf8))
        }
    }

    @Test func captionStateSurvivesTheInteractionEventEnvelope() throws {
        let callID = UUID()
        let segment = CallCaptionSegment(id: UUID(), speaker: "Taylor", text: "Bonjour.")
        var activities = CallActivitiesState()
        activities.availableActions = ["captions"]
        activities.ownHandLowered = UUID()
        activities.captionLanguages = CallCaptionLanguages(
            live: ["en-US"],
            translations: ["en-US": ["fr-FR"]]
        )
        activities.captions = CallCaptionState(
            spokenLanguage: "en-US", displayLanguage: "fr-FR", segments: [segment]
        )
        var state = CallInteractionState()
        state.activities = activities
        let event = AudioCallEvent.interactionChanged(callID: callID, state: state)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AudioCallEvent.self, from: data)
        guard case let .interactionChanged(id, snapshot) = decoded else {
            Issue.record("Expected an interaction event")
            return
        }
        #expect(id == callID && snapshot?.activities?.captions == activities.captions)
        #expect(snapshot?.activities?.captionLanguages == activities.captionLanguages)
        #expect(snapshot?.activities?.ownHandLowered == activities.ownHandLowered)
    }

    @Test func artifactFilesRoundTripThroughTheCallInteractionEnvelope() throws {
        var activities = CallActivitiesState()
        activities.breakoutClosed = true
        activities.artifacts = [
            .init(
                kind: "recording",
                phase: "starting",
                issue: CallArtifactIssue.participantCompatibility.rawValue
            ),
            .init(kind: "transcription", phase: "stopped", issue: "futureIssue")
        ]
        activities.artifactFiles = try [.init(
            kind: "recording", title: "Design review",
            url: #require(URL(string: "https://drive.google.com/file/d/fixture/view"))
        )]
        activities.agendaAttachments = try [.init(
            title: "Agenda",
            url: #require(URL(string: "https://files.example.test/agenda"))
        )]
        activities.agendaGuests = [
            .init(
                id: UUID(),
                displayName: "Guest",
                response: "futureStatus",
                chatAddress: "guest@example.test"
            )
        ]
        var state = CallInteractionState()
        state.activities = activities
        let event = AudioCallEvent.interactionChanged(callID: UUID(), state: state)
        let wire = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(AudioCallEvent.self, from: wire) == event)
        let legacy = try JSONDecoder().decode(
            CallArtifact.self, from: Data(#"{"kind":"recording","phase":"stopped"}"#.utf8)
        )
        #expect(legacy.issue == nil && legacy.canSetEnabled(true))
    }
}
