import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The menu bar's Call menu: the call window's titles, and its rules for
/// when each control works.
struct CallMenuTests {
    private let id = UUID()
    private let recipient = AudioCallRecipient(
        conversationID: Conversation.ID("dm"), memberID: Member.ID("peer"), displayName: "Peer"
    )

    private func call(_ phase: AudioCallPhase, muted: Bool = false) -> AudioCallSession {
        AudioCallSession(AudioCallSnapshot(
            id: id, recipient: recipient, direction: .outgoing, phase: phase, isMuted: muted
        ))
    }

    private func menu(
        _ call: AudioCallSession?, ending: Bool = false, camera: CallCameraState? = CallCameraState(),
        sharing: CallScreenShareState? = CallScreenShareState(), video: Bool = true, sound: Bool = false
    ) -> CallMenu {
        CallMenu(
            call: call, isEnding: ending, camera: camera, screenSharing: sharing, offersVideo: video,
            offersSound: sound
        )
    }

    private func enabled(_ menu: CallMenu) -> [CallMenu.Item] {
        menu.entries.filter(\.isEnabled).map(\.item)
    }

    @Test func aConnectedCallEnablesEveryItem() {
        let connected = menu(call(.connected))
        #expect(connected.callID == id)
        #expect(connected.entries.map(\.item) == [.mute, .camera, .shareScreen, .endCall])
        #expect(connected.entries.map(\.title) == ["Mute", "Turn Camera On", "Share Screen…", "End Call"])
        #expect(enabled(connected) == [.mute, .camera, .shareScreen, .endCall])
        #expect(connected.entries.first?.shortcut == MenuBarShortcuts.muteCall)
        #expect(connected.entries.dropFirst().allSatisfy { $0.shortcut == nil })
    }

    /// As the call window's control bar: media while ringing or connected,
    /// End Call from the moment a call starts connecting.
    @Test func eachPhaseEnablesWhatTheCallWindowDoes() {
        #expect(enabled(menu(call(.connecting))) == [.endCall])
        #expect(enabled(menu(call(.ringing))) == [.mute, .camera, .shareScreen, .endCall])
        for phase in [AudioCallPhase.incoming, .ended, .declined, .failed] {
            #expect(enabled(menu(call(phase))).isEmpty, "\(phase)")
            #expect(menu(call(phase)).callID == nil)
        }
        #expect(enabled(menu(nil)).isEmpty)
        #expect(enabled(menu(call(.connected), ending: true)).isEmpty)
        #expect(menu(call(.connected), ending: true).callID == nil)
    }

    @Test func titlesFollowTheCallsState() {
        var on = CallCameraState()
        on.isOn = true
        let muted = menu(
            call(.connected, muted: true),
            camera: on,
            sharing: CallScreenShareState(phase: .sharing)
        )
        #expect(muted.entries.map(\.title) == ["Unmute", "Turn Camera Off", "Stop Sharing", "End Call"])
        #expect(muted.entries.map(\.symbol) == [
            "mic",
            "video.slash",
            "rectangle.on.rectangle.slash",
            "phone.down"
        ])
        let phases: [CallScreenShareState.Phase] = [.idle, .preparing, .sharing, .stopping]
        #expect(phases.map(CallMenu.sharingTitle) == [
            "Share Screen…", "Cancel Sharing", "Stop Sharing", "Stopping Sharing…"
        ])
    }

    @Test func aCameraOrShareOnItsWayWaits() {
        var changing = CallCameraState()
        changing.isUpdating = true
        #expect(enabled(menu(call(.connected), camera: changing)) == [.mute, .shareScreen, .endCall])
        let stopping = CallScreenShareState(phase: .stopping)
        #expect(enabled(menu(call(.connected), sharing: stopping)) == [.mute, .camera, .endCall])
        // Not yet installed for this call: drawn, not enabled.
        #expect(enabled(menu(call(.connected), camera: nil, sharing: nil)) == [.mute, .endCall])
    }

    @Test func callsWithoutVideoDrawNoCameraOrSharing() {
        #expect(menu(call(.connected), video: false).entries.map(\.item) == [.mute, .endCall])
    }

    @Test func theHandShortcutFollowsTheConnectedCallAndItsPendingChange() throws {
        let raised = CallMenu(
            call: call(.connected), isEnding: false, camera: nil, screenSharing: nil,
            offersVideo: false, handRaised: true, isUpdatingHand: true
        )
        let hand = try #require(raised.entries.first { $0.item == .toggleHand })
        #expect(hand.title == "Lower Hand")
        #expect(hand.shortcut == MenuBarShortcuts.toggleCallHand)
        #expect(!hand.isEnabled)
        let ringing = CallMenu(
            call: call(.ringing), isEnding: false, camera: nil, screenSharing: nil,
            offersVideo: false, handRaised: false
        )
        #expect(!ringing.entries.contains { $0.item == .toggleHand })
    }

    @Test func lockedParticipantDevicesDisableOnlyTheirControls() {
        let restricted = CallMenu(
            call: call(.connected, muted: true), isEnding: false,
            camera: CallCameraState(allowsStart: false), screenSharing: CallScreenShareState(),
            offersVideo: true, microphoneRestricted: true
        )
        #expect(enabled(restricted) == [.shareScreen, .endCall])
    }

    @Test func lockedSharingDisablesBothStartsButCanStillStop() {
        let locked = CallScreenShareState(allowsStart: false)
        let lockedMenu = menu(call(.connected), sharing: locked, sound: true)
        #expect(lockedMenu.entries.contains { $0.item == .shareScreen })
        #expect(!enabled(lockedMenu).contains(.shareScreen))
        #expect(!enabled(lockedMenu).contains(.shareScreenWithSound))
        let stillSharing = CallScreenShareState(phase: .sharing, allowsStart: false)
        #expect(enabled(menu(call(.connected), sharing: stillSharing)).contains(.shareScreen))
    }

    @Test func copyingANewLinkIsIndependentFromJoiningOrEndingACall() {
        let active = CallMenu(
            call: call(.connected), isEnding: false, camera: nil, screenSharing: nil, offersVideo: false,
            offersMeetingLinks: true, offersMeetingLinkCreation: true
        )
        #expect(active.entries.first?.item == .createMeetingLink)
        #expect(enabled(active) == [.createMeetingLink, .mute, .endCall])

        let pending = CallMenu(
            call: nil, isEnding: false, camera: nil, screenSharing: nil, offersVideo: false,
            offersMeetingLinks: true, offersMeetingLinkCreation: true, isCreatingMeetingLink: true
        )
        #expect(enabled(pending) == [.joinMeeting])
    }
}
