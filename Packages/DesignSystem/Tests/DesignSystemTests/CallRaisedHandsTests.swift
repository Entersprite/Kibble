import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallRaisedHandsTests {
    @Test func noticeCombinesFreshRaisesAndSkipsJoinsGapsAndAnOpenQueue() throws {
        let priya = CallRaisedHandsPresentation.Hand(id: UUID(), name: "Priya")
        let dan = CallRaisedHandsPresentation.Hand(id: UUID(), name: "Dan")
        let maya = CallRaisedHandsPresentation.Hand(id: UUID(), name: "Maya")
        var notice = CallRaisedHandsPresentation()
        func receive(_ hands: [CallRaisedHandsPresentation.Hand]?, queueOpen: Bool = false) -> Bool {
            notice.receive(hands, queueOpen: queueOpen)
        }
        #expect(!receive([priya]))
        #expect(receive([priya, dan]))
        let first = try #require(notice.event)
        #expect(notice.message == "Dan raised their hand")
        #expect(receive([priya, dan, maya]))
        #expect(notice.message == "Dan and Maya raised their hands")
        notice.dismiss(first)
        #expect(notice.message != nil)
        #expect(!receive([priya, dan, maya], queueOpen: true))
        #expect(notice.message == nil)
        #expect(!receive(nil))
        #expect(!receive([maya]))
        #expect(notice.message == nil)
        #expect(!receive([]))
        #expect(receive([maya]))
    }

    @Test func aRosterWithoutKnownHandStateDoesNotSeedTheNotice() {
        let joined = CallParticipantDevice(id: UUID())
        #expect(CallRaisedHandsPresentation.knownHands(in: [joined]) == nil)
        let raised = CallParticipantDevice(id: joined.id, displayName: "Dan", handRaised: true)
        let selfView = CallParticipantDevice(id: UUID(), isLocal: true, handRaised: true)
        #expect(CallRaisedHandsPresentation.knownHands(in: [raised, selfView])?.map(\.name) == ["Dan"])
    }

    @Test func aFreshHandShowsTheHostedNoticeUntilPeopleOpens() {
        let id = UUID()
        func notice(raised: Bool, queueOpen: Bool) -> CallRaisedHandsNotice {
            CallRaisedHandsNotice(
                participants: [CallParticipantDevice(id: id, displayName: "Priya", handRaised: raised)],
                canOpenQueue: true, showsPeople: .constant(queueOpen)
            )
        }
        let host = NSHostingView(rootView: notice(raised: false, queueOpen: false))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 84),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        #expect(host.fittingSize.height == 0)
        host.rootView = notice(raised: true, queueOpen: false)
        settle()
        #expect(host.fittingSize.height >= 40)
        host.rootView = notice(raised: true, queueOpen: true)
        settle()
        #expect(host.fittingSize.height == 0)
        withExtendedLifetime(window) {}
    }

    @Test func raisedHandsIdentifyTheCameraAndReserveItsPlaceInTheCappedGrid() throws {
        let normal = (0 ..< 4).map { _ in CallParticipantDevice(id: UUID()) }
        let raised = CallParticipantDevice(id: UUID(), handRaised: true)
        let joined = normal + [raised]
        let cameras = joined.enumerated().map {
            CallRemoteVideo(
                id: $0.offset,
                participantID: $0.element.id,
                isScreen: false,
                content: AnyView(Color.gray)
            )
        }
        let presentation = CallRemoteVideo(
            id: 5, participantID: raised.id, isScreen: true, content: AnyView(Color.blue)
        )
        let tiles = CallStageSelection.videos(cameras + [presentation], roster: nil, participants: joined)
        let raisedLabel = try #require(CallRoster.disambiguatedNames(in: joined)[raised.id])
        #expect(tiles.filter(\.handRaised).map(\.id) == [4])
        #expect(raisedLabel.hasPrefix("Participant (device "))
        #expect(CallVideoTile.label(for: tiles[4], muted: false) == "\(raisedLabel)’s camera, hand raised")
        #expect(CallVideoTile.label(for: tiles[5], muted: false) == "\(raisedLabel)’s shared screen")
        let selection = CallStageSelection(layoutPreferences: .init(layout: .tiled, tileLimit: .four))
        #expect(selection.gridVideos(tiles, ownTile: nil).map(\.id) == [4, 0, 1, 2])
        #expect(selection.receivePreferences == CallVideoPreferences())
    }

    @Test func callWithRaisedHandsRendersCameraBadgesAndTheQueueNotice() throws {
        let peer = CallParticipantDevice(id: UUID(), displayName: "Priya", handRaised: true)
        let call = AudioCallSession(ConversationCallSnapshot(
            id: UUID(), target: .init(conversationID: .init("demo"), displayName: "Call with Priya"),
            phase: .connected
        ))
        var actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
        actions.handRaised = true
        actions.toggleHandRaised = {}
        let remote = CallRemoteVideo(
            id: 0, participantID: peer.id, label: "Priya", isScreen: false, content: AnyView(Color.blue)
        )
        let view = AudioCallView(
            call: call, actions: actions, participants: [peer],
            video: CallVideoContent(remotes: [remote], preview: AnyView(Color.green))
        )
        try render(view.frame(width: 760, height: 480), name: "RaisedHandTiles", minimumHeight: 480)
        let banner = CallRaisedHandsBanner(message: "Priya raised their hand", openQueue: {}, dismiss: {})
        try render(
            banner.foregroundStyle(.white).environment(\.colorScheme, .dark).background(Color.black),
            name: "RaisedHandBanner", minimumHeight: 45
        )
    }

    private func render(_ view: some View, name: String, minimumHeight: CGFloat) throws {
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        #expect(host.frame.height >= minimumHeight)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_RAISED_HAND_RENDERS"] {
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
