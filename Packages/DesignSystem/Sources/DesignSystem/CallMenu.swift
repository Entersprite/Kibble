import ChatKit
import SwiftUI

/// The menu bar's Call menu: Mute, the camera, sharing and End Call for the
/// call that holds this Mac's microphone, with the call window's own titles
/// and the same rules for when each works (`CallControlBar`).
///
/// Pure, from values the host observes, so a test can read it. The camera
/// and sharing are drawn only where the host's calls can carry video. There
/// is no Accept or Decline: an incoming call is answered in its panel or
/// window, never by a key that could be pressed while typing.
public struct CallMenu: Equatable, Sendable {
    public enum Item: Hashable, Sendable {
        case createMeetingLink, joinMeeting, mute, camera, shareScreen, shareScreenWithSound, toggleHand,
             endCall
    }

    public struct Entry: Hashable, Identifiable, Sendable {
        public let item: Item
        public let title: String
        public let symbol: String
        public let shortcut: KeyboardShortcut?
        public let isEnabled: Bool

        public var id: Item {
            item
        }
    }

    /// The call the enabled items act on; `nil` while no call holds the device.
    public let callID: UUID?
    public let entries: [Entry]

    /// `call` is the account's current call, whatever its phase: only one
    /// that has started and not finished is acted on. A ring waiting for an
    /// answer holds nothing.
    public init(
        call: AudioCallSession?, isEnding: Bool, camera: CallCameraState?,
        screenSharing: CallScreenShareState?, offersVideo: Bool, offersSound: Bool = false,
        offersMeetingLinks: Bool = false, offersMeetingLinkCreation: Bool = false,
        isCreatingMeetingLink: Bool = false, microphoneRestricted: Bool = false,
        handRaised: Bool? = nil, isUpdatingHand: Bool = false
    ) {
        let live = call.flatMap { $0.phase.isTerminal || $0.phase == .incoming || isEnding ? nil : $0 }
        let media = live.map { AudioCallPresentation.canMute($0.phase) } ?? false
        callID = live?.id
        let muted = live?.isMuted ?? false
        var entries = [Entry(
            item: .mute, title: muted ? "Unmute" : "Mute", symbol: muted ? "mic" : "mic.slash",
            shortcut: MenuBarShortcuts.muteCall, isEnabled: media && !microphoneRestricted
        )]
        if offersMeetingLinks {
            entries.insert(Entry(
                item: .joinMeeting, title: "Join Meeting…", symbol: "link", shortcut: nil,
                isEnabled: live == nil && call?.phase != .incoming && !isEnding
            ), at: 0)
        }
        if offersMeetingLinkCreation {
            entries.insert(Entry(
                item: .createMeetingLink, title: "Copy New Meeting Link", symbol: "link.badge.plus",
                shortcut: nil,
                isEnabled: !isCreatingMeetingLink
            ), at: 0)
        }
        if offersVideo {
            entries += Self.videoEntries(
                camera: camera, screenSharing: screenSharing, offersSound: offersSound, media: media
            )
        }
        if let handRaised, live?.phase == .connected {
            entries.append(Entry(
                item: .toggleHand, title: Self.handTitle(handRaised), symbol: "hand.raised",
                shortcut: MenuBarShortcuts.toggleCallHand, isEnabled: !isUpdatingHand
            ))
        }
        entries.append(Entry(
            item: .endCall, title: "End Call", symbol: "phone.down", shortcut: nil,
            isEnabled: live.map { AudioCallPresentation.canHangUp($0.phase) } ?? false
        ))
        self.entries = entries
    }

    private static func videoEntries(
        camera: CallCameraState?, screenSharing: CallScreenShareState?, offersSound: Bool, media: Bool
    ) -> [Entry] {
        let isOn = camera?.isOn ?? false
        var entries = [Entry(
            item: .camera, title: isOn ? "Turn Camera Off" : "Turn Camera On",
            symbol: isOn ? "video.slash" : "video", shortcut: nil,
            isEnabled: media && camera?.canToggle == true
        )]
        let sharing = screenSharing?.phase ?? .idle
        entries.append(Entry(
            item: .shareScreen, title: Self.sharingTitle(sharing),
            symbol: sharing == .idle ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash",
            shortcut: nil, isEnabled: media && screenSharing?.canToggle == true
        ))
        // Its own item, so sound is only ever shared by choosing it.
        if offersSound {
            entries.append(Entry(
                item: .shareScreenWithSound, title: Self.shareWithSoundTitle, symbol: "speaker.wave.2",
                shortcut: nil, isEnabled: media && sharing == .idle && screenSharing?.allowsStart == true
            ))
        }
        return entries
    }

    static let shareWithSoundTitle = "Share Screen with Sound…"

    static func handTitle(_ isRaised: Bool) -> String {
        isRaised ? "Lower Hand" : "Raise Hand"
    }

    /// The call window's sharing button says the same at each step.
    static func sharingTitle(_ phase: CallScreenShareState.Phase) -> String {
        switch phase {
        case .idle: "Share Screen…"
        case .preparing: "Cancel Sharing"
        case .sharing: "Stop Sharing"
        case .stopping: "Stopping Sharing…"
        }
    }
}
