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
        selection.togglePin(camera)
        #expect(selection.main(in: videos)?.id == 0)
        #expect(selection.stage(in: videos) == .presentation)
        selection.togglePin(camera)
        selection.layoutPreferences.layout = .tiled
        #expect(selection.stage(in: videos) == .grid(columns: 2))
        selection.layoutPreferences.layout = .spotlight; selection.activeSpeaker = cameraPerson
        #expect(selection.main(in: [camera])?.participantID == cameraPerson)
        let rebound = CallRemoteVideo(
            id: 5,
            participantID: cameraPerson,
            isScreen: false,
            content: AnyView(Color.black)
        )
        selection.togglePin(camera)
        #expect(selection.isPinned(rebound))
    }

    @Test func matchingParticipantNamesIdentifyExactDevicesAndTheirTiles() throws {
        let first = try CallParticipantDevice(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")), displayName: "Taylor"
        )
        let second = try CallParticipantDevice(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            displayName: " Taylor ", handRaised: true
        )
        let screen = CallParticipantDevice(
            id: UUID(), displayName: "Taylor", parentID: second.id, isPresentation: true
        )
        let local = CallParticipantDevice(id: UUID(), displayName: "Taylor", isLocal: true)
        let people = [second, screen, local, first]
        let labels = CallRoster.disambiguatedNames(in: people)
        #expect(labels == [
            first.id: "Taylor (device 1)",
            second.id: "Taylor (device 2)",
            screen.id: "Taylor (device 2)"
        ])
        #expect(CallRoster.disambiguatedNames(in: people.reversed()) == labels)
        #expect(CallRoster.disambiguatedNames(in: [second, screen, local]).isEmpty)

        let roster = try #require(CallRoster.entries(people))
        #expect(roster.map(\.name) == ["Taylor", "Taylor"])
        #expect(roster.map(\.label) == ["Taylor (device 1)", "Taylor (device 2)"])
        let live = CallRemoteVideo(
            id: 1, participantID: first.id, label: "Taylor", isScreen: false, content: AnyView(Color.black)
        )
        let videos = CallStageSelection.videos([live], roster: roster, participants: people)
        #expect(videos.map(\.label) == ["Taylor (device 1)", "Taylor (device 2)", "Taylor (device 2)"])
        var selection = CallStageSelection()
        selection.observeParticipants(people)
        let secondCamera = try #require(videos.first { $0.participantID == second.id })
        selection.togglePin(secondCamera)
        #expect(selection.receivePreferences.personalPins == [second.id])
        #expect(!selection.isPinned(live))
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
            CallVideoStage(videos: videos, roster: roster, selection: .constant(CallStageSelection()))
                .frame(width: 480, height: 320)
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

    @Test func sharedPinsFollowDeviceIdentityAndCanBeDismissedLocallyUntilCleared() throws {
        let person = CallParticipantDevice(id: UUID(), isPinnedForEveryone: true)
        let screen = CallParticipantDevice(id: UUID(), isPresentation: true, isPinnedForEveryone: true)
        let ordinary = CallParticipantDevice(id: UUID())
        let videos = [ordinary, person, screen].enumerated().map { index, device in
            CallRemoteVideo(
                id: index,
                participantID: device.id,
                isScreen: device.isPresentation,
                content: AnyView(Color.black)
            )
        }
        var selection = CallStageSelection()
        selection.togglePin(videos[0])
        selection.observeParticipants([ordinary, person, screen])
        let focused = try #require(selection.main(in: videos))
        #expect(focused.participantID == person.id)
        #expect(selection.primaryVideos(in: videos).map(\.participantID) == [
            person.id,
            screen.id,
            ordinary.id
        ])
        #expect(selection.filmstrip(in: videos).isEmpty)
        selection.togglePin(focused)
        #expect(selection.main(in: videos)?.participantID == screen.id)
        #expect(selection.receivePreferences.personalPins == [ordinary.id])
        #expect(selection.receivePreferences.dismissedSharedPins == [person.id])
        selection.observeParticipants(nil)
        selection.observeParticipants([person, screen])
        #expect(selection.main(in: videos)?.participantID == screen.id)
        selection.observeParticipants([screen])
        selection.observeParticipants([person, screen])
        #expect(selection.main(in: videos)?.participantID == person.id)
        #expect(selection.receivePreferences.dismissedSharedPins.isEmpty)
    }

    @Test func personalPinsKeepSixExactTargetsAndYieldTheNewestPlaceToASharedPin() throws {
        let devices = (0 ..< 8).map { CallParticipantDevice(id: UUID(), displayName: "Person \($0)") }
        let videos = CallStageSelection.videos([], roster: CallRoster.entries(devices))
        var selection = CallStageSelection()
        for video in videos.prefix(7) {
            selection.togglePin(video)
        }
        #expect(selection.pinCount == 6)
        #expect(selection.primaryVideos(in: videos).map(\.id) == Array(videos.prefix(6)).map(\.id))
        #expect(selection.filmstrip(in: videos).map(\.id) == Array(videos.suffix(2)).map(\.id))
        let sharedID = try #require(videos[7].participantID)
        let current = devices.map {
            CallParticipantDevice(
                id: $0.id,
                displayName: $0.displayName,
                isPinnedForEveryone: $0.id == sharedID
            )
        }
        selection.observeParticipants(current)
        #expect(selection.pinCount == 6)
        #expect(selection.primaryVideos(in: videos).map(\.id) == [videos[7].id] + videos.prefix(5).map(\.id))
        #expect(!selection.isPinned(videos[5]))
        #expect(!selection.canTogglePin(videos[6]))
        selection.togglePin(videos[7])
        #expect(selection.canTogglePin(videos[6]))
        selection.togglePin(videos[6])
        selection.observeParticipants(nil)
        #expect(selection.isPinned(videos[6]))
        selection.observeParticipants(current.filter { $0.id != videos[6].participantID })
        #expect(!selection.isPinned(videos[6]))
        #expect(!selection.canTogglePin(videos[6]))
    }

    @Test func aPresentationCanBePinnedFromTheRosterBeforeItHasAReceiveSlot() throws {
        let person = CallParticipantDevice(id: UUID(), displayName: "Taylor")
        let screen = CallParticipantDevice(
            id: UUID(), displayName: "Taylor", parentID: person.id, isPresentation: true
        )
        let participants = [person, screen]
        let roster = CallRoster.entries(participants)
        let candidates = CallStageSelection.videos([], roster: roster, participants: participants)
        let camera = try #require(candidates.first(where: { !$0.isScreen }))
        let placeholder = try #require(candidates.first(where: { $0.isScreen }))
        var selection = CallStageSelection()
        #expect(selection.visibleVideos(from: candidates).map(\.participantID) == [person.id])
        selection.togglePin(placeholder)
        selection.togglePin(camera)
        let stream = CallRemoteVideo(
            id: 7, participantID: screen.id, label: "Taylor", isScreen: true, content: AnyView(Color.blue)
        )
        let received = CallStageSelection.videos([stream], roster: roster, participants: participants)
        #expect(selection.primaryVideos(in: received).map(\.id) == [stream.id, camera.id])
        #expect(selection.isPinned(stream))
        selection.togglePin(stream)
        #expect(selection.primaryVideos(in: received).map(\.id) == [camera.id])
    }

    @Test func twoPinnedTilesAndPeopleControlsRenderWithoutShowingWindows() throws {
        let camera = CallParticipantDevice(id: UUID(), displayName: "Interpreter")
        let screen = CallParticipantDevice(id: UUID(), displayName: "Presenter", isPresentation: true)
        let people = [camera, screen]
        let roster = CallRoster.entries(people)
        let videos = people.enumerated().map { index, device in
            CallRemoteVideo(
                id: index, participantID: device.id, label: device.displayName,
                isScreen: device.isPresentation,
                content: AnyView(device.isPresentation ? Color.blue : Color.purple)
            )
        }
        var selection = CallStageSelection()
        selection.observeParticipants(people)
        videos.forEach { selection.togglePin($0) }
        let view = HStack(alignment: .top) {
            CallVideoStage(videos: videos, roster: roster, selection: .constant(selection))
                .frame(width: 580, height: 360)
            CallPeopleList(
                entries: roster, personalVideo: CallPersonalVideoControls(
                    selection: .constant(selection),
                    videos: videos
                )
            )
        }.background(.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(host.frame.width >= 840)
        if let output = ProcessInfo.processInfo.environment["KIBBLE_PERSONAL_PINS_RENDER"] {
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
    }

    @Test func hiddenFeedsFollowExactRemoteTilesAndKeepPinsForRestoration() throws {
        let camera = CallParticipantDevice(id: UUID(), displayName: "Taylor")
        let screen = CallParticipantDevice(
            id: UUID(), displayName: "Taylor", parentID: camera.id, isPresentation: true
        )
        let local = CallParticipantDevice(id: UUID(), displayName: "You", isLocal: true)
        let devices = [camera, screen, local]
        let roster = CallRoster.entries(devices)
        let received = CallRemoteVideo(
            id: 0, participantID: screen.id, label: "Taylor", isScreen: true, content: AnyView(Color.blue)
        )
        let candidates = CallStageSelection.videos([received], roster: roster, participants: devices)
        let placeholder = try #require(candidates.first { $0.participantID == camera.id })
        var selection = CallStageSelection()
        selection.observeParticipants(devices)
        selection.togglePin(placeholder)
        selection.toggleVideoFeed(camera.id)
        selection.toggleVideoFeed(local.id)
        #expect(selection.receivePreferences.hiddenVideoFeeds == [camera.id])
        #expect(selection.visibleVideos(from: candidates).map(\.participantID) == [screen.id])
        #expect(selection.remoteVideoFeeds.map(\.id) == [camera.id, screen.id])
        #expect(selection.videoFeed(for: placeholder)?.id == camera.id)
        #expect(selection.isPinned(placeholder))
        selection.observeParticipants(nil)
        #expect(selection.receivePreferences.hiddenVideoFeeds == [camera.id])
        selection.toggleVideoFeed(camera.id)
        #expect(selection.main(in: selection.visibleVideos(from: candidates))?.participantID == camera.id)

        selection.toggleVideoFeed(screen.id)
        #expect(selection.visibleVideos(from: candidates).map(\.participantID) == [camera.id])
        selection.observeParticipants([camera, local])
        selection.toggleVideoFeed(screen.id)
        #expect(selection.receivePreferences.hiddenVideoFeeds.isEmpty)
        #expect(selection.videoFeed(for: received) == nil)
    }
}
