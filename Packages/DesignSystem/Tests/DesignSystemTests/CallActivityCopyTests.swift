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
