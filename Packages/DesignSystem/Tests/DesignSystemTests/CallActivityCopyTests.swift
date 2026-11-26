import ChatKit
import Foundation
import Testing
@testable import DesignSystem

@MainActor
struct CallActivityCopyTests {
    @Test func artifactsAreNamedInWordsAPersonReads() {
        #expect(CallArtifactPresentation.title("notes") == "Notes")
        #expect(CallArtifactPresentation.status("preconfigured") == "Off")
        #expect(CallArtifactPresentation.status("active") == "On")
        #expect(CallArtifactPresentation.status("unknown") == nil)
        #expect(CallArtifactPresentation.startQuestion("recording") == "Start Recording?")
        let recording = CallArtifact(kind: "recording", phase: "active", recordingCaptionLanguage: "fr-FR")
        #expect(CallArtifactPresentation.notice(for: recording) == "This call is being recorded")
        #expect(CallActivitiesView.status(of: recording) { _ in "French" } == "On · Captions in French")
        let notices = CallArtifactPresentation.notices(for: [
            recording, CallArtifact(kind: "notes", phase: "starting"),
            CallArtifact(kind: "transcription", phase: "stopped")
        ])
        #expect(notices.map(\.text) == ["This call is being recorded", "Notes are starting"])
    }

    @Test func countsAndListsReadNaturally() {
        #expect(CallActivityCopy.votes(1) == "1 vote")
        #expect(CallActivityCopy.votes(0) == "0 votes")
        #expect(CallActivityCopy.filled([" One ", "", "  ", "Two"]) == ["One", "Two"])
        let room = CallBreakoutRoom(id: UUID(), name: "Design", isOpen: true, participants: [UUID()])
        #expect(CallActivityRoomsView.subtitle(for: room) == "Open · 1 person")
        #expect(CallActivityRoomsView.subtitle(for: room, closing: true) == "Closing · 1 person")
        #expect(CallActivityRoomsView.subtitle(for: room, isCurrent: true) == "Current room · 1 person")
    }

    @Test func closingNoticeAppearsOnlyWhileConnectedInAClosingBreakout() {
        var activities = CallActivitiesState()
        activities.breakoutClosing = true
        #expect(AudioCallPresentation.breakoutClosingNotice(phase: .connected, activities: activities) == nil)

        activities.availableActions = ["returnToMainRoom"]
        let notice = AudioCallPresentation.breakoutClosingNotice(phase: .connected, activities: activities)
        #expect(notice?.text == "Breakout rooms are closing. You’ll return to the main call.")
        #expect(notice?.kind == .info)
        #expect(AudioCallPresentation
            .breakoutClosingNotice(phase: .connecting, activities: activities) == nil)

        activities.breakoutClosing = nil
        activities.breakoutClosed = true
        #expect(AudioCallPresentation.breakoutClosingNotice(phase: .connected, activities: activities) == nil)
    }

    @Test func captureFailuresUseWarningsWithoutChangingOrdinaryRecordingNotices() {
        let blocked = CallArtifact(
            kind: "recording", phase: "starting", issue: CallArtifactIssue.participantCompatibility.rawValue
        )
        var failed = CallArtifact(
            kind: "transcription", phase: "stopped", issue: CallArtifactIssue.initializationFailed.rawValue
        )
        #expect(CallActivitiesView.status(of: blocked) { $0 } == "Blocked by a participant’s device")
        #expect(CallActivitiesView.status(of: failed) { $0 } == "Couldn’t start")
        let notices = CallArtifactPresentation.notices(for: [blocked, failed])
        #expect(notices.map(\.kind) == [.warning, .warning])
        #expect(notices.map(\.text) == [
            "Recording is blocked by a participant’s device", "Transcription couldn’t start"
        ])
        failed.phase = "active"
        #expect(CallArtifactPresentation.notices(for: [failed]).map(\.kind) == [.info])
        #expect(CallArtifactPresentation.notice(for: failed) == "This call is being transcribed")
    }

    @Test func chatNamesASenderOncePerRunAndNeverTheReader() {
        func message(_ id: String, _ sender: Member.ID, _ text: String) -> Message {
            Message(
                id: .init(id), conversationID: .init("room"), threadID: .init("thread"), sender: sender,
                text: text, createdAt: Date(timeIntervalSince1970: 1)
            )
        }
        let me = Member.ID("me"), peer = Member.ID("peer")
        let rows = CallChatRow.rows(
            [
                message("1", peer, "a"),
                message("2", peer, "b"),
                message("3", me, "c"),
                message("4", peer, "d")
            ],
            directory: [peer: Member(id: peer, kind: .human, displayName: "Taylor")], me: me
        )
        #expect(rows.map(\.sender) == ["Taylor", nil, nil, "Taylor"])
        #expect(rows.map(\.isMine) == [false, false, true, false])
    }
}
