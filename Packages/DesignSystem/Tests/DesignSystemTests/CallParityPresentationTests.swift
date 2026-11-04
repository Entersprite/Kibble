import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallParityPresentationTests {
    private func message(_ id: String, _ status: MessageCallStatus) -> Message {
        Message(
            id: .init(id),
            conversationID: .init("room"),
            threadID: .init("thread"),
            sender: .init("peer"),
            text: "",
            createdAt: Date(timeIntervalSince1970: 1),
            callStatus: status
        )
    }

    @Test func historyAloneNeverOffersJoinAndOnlyTheLatestEntryBorrowsFreshActivity() {
        let old = message("old", .started), current = message("new", .started)
        var state = ChatSceneState(selected: .init("room"), messages: [old, current])
        #expect(!TranscriptCallControl.offersAction(for: current, in: state))
        state.callOffer = .join(participants: 2)
        #expect(TranscriptCallControl.offersAction(for: current, in: state))
        #expect(!TranscriptCallControl.offersAction(for: old, in: state))
        state.messages.append(message("ended", .ended))
        #expect(!TranscriptCallControl.offersAction(for: current, in: state))
        state.messages = [current]; state.hasNewerMessages = true
        #expect(!TranscriptCallControl.offersAction(for: current, in: state))
        state.hasNewerMessages = false; state.callOffer = .returnToCall
        #expect(TranscriptCallControl.offersAction(for: current, in: state))
    }

    @Test func aSupportedMeetingLinkUsesTheCallActionRatherThanAnExternalOpen() throws {
        let url = try #require(URL(string: "https://meet.example.test/room"))
        var joined: URL?
        let action = LinkPolicy.openURLAction(
            blocking: [],
            meetingHosts: ["meet.example.test"],
            join: { joined = $0 }
        )
        action(url)
        #expect(joined == url)
    }

    @Test func cameraOffParticipantsKeepTheirTilesBesidePresentations() {
        let person = UUID(), cameraPerson = UUID()
        let roster = CallRoster.entries([
            CallParticipantDevice(id: person, displayName: "Camera off"),
            CallParticipantDevice(id: cameraPerson, displayName: "Camera on")
        ])
        let camera = CallRemoteVideo(
            id: 0,
            participantID: cameraPerson,
            isScreen: false,
            content: AnyView(Color.black)
        )
        let screen = CallRemoteVideo(
            id: 1,
            participantID: person,
            isScreen: true,
            content: AnyView(Color.black)
        )
        let videos = CallStageSelection.videos([camera, screen], roster: roster)
        #expect(videos.count == 3)
        #expect(videos.filter { $0.participantID == person }.count == 2)
        var selection = CallStageSelection()
        selection.pinned = CallStageSelection.key(camera)
        #expect(selection.main(in: videos)?.id == 0)
        #expect(selection.stage(in: videos) == .presentation)
        selection.pinned = nil; selection.layout = .tiled
        #expect(selection.stage(in: videos) == .grid(columns: 2))
        selection.layout = .spotlight; selection.activeSpeaker = cameraPerson
        #expect(selection.main(in: [camera])?.participantID == cameraPerson)
        let rebound = CallRemoteVideo(
            id: 5,
            participantID: cameraPerson,
            isScreen: false,
            content: AnyView(Color.black)
        )
        #expect(CallStageSelection.key(camera) == CallStageSelection.key(rebound))
    }

    @Test func joinAndCameraOffStageRenderWithoutShowingWindows() throws {
        let roster = CallRoster.entries([CallParticipantDevice(
            id: UUID(),
            displayName: "Taylor",
            microphoneMuted: true
        )])
        let videos = CallStageSelection.videos([], roster: roster)
        let view = VStack {
            CallMessageCard(status: .started, join: {})
            CallVideoStage(videos: videos, roster: roster).frame(width: 480, height: 320)
        }.padding(20).background(.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(host.frame.width >= 480)
        if let output = ProcessInfo.processInfo.environment["KIBBLE_CALL_PARITY_RENDER"] {
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
    }
}
