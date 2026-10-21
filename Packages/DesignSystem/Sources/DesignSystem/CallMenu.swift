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
        case mute, camera, shareScreen, endCall
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
        call: AudioCallSnapshot?, isEnding: Bool, camera: CallCameraState?,
        screenSharing: CallScreenShareState?, offersVideo: Bool
    ) {
        let live = call.flatMap { $0.phase.isTerminal || $0.phase == .incoming || isEnding ? nil : $0 }
        let media = live.map { AudioCallPresentation.canMute($0.phase) } ?? false
        callID = live?.id
        let muted = live?.isMuted ?? false
        var entries = [Entry(
            item: .mute, title: muted ? "Unmute" : "Mute", symbol: muted ? "mic" : "mic.slash",
            shortcut: MenuBarShortcuts.muteCall, isEnabled: media
        )]
        if offersVideo {
            let isOn = camera?.isOn ?? false
            entries.append(Entry(
                item: .camera, title: isOn ? "Turn Camera Off" : "Turn Camera On",
                symbol: isOn ? "video.slash" : "video", shortcut: nil,
                isEnabled: media && camera.map { !$0.isUpdating } == true
            ))
            let sharing = screenSharing?.phase ?? .idle
            entries.append(Entry(
                item: .shareScreen, title: Self.sharingTitle(sharing),
                symbol: sharing == .idle ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash",
                shortcut: nil, isEnabled: media && screenSharing.map { $0.phase != .stopping } == true
            ))
        }
        entries.append(Entry(
            item: .endCall, title: "End Call", symbol: "phone.down", shortcut: nil,
            isEnabled: live.map { AudioCallPresentation.canHangUp($0.phase) } ?? false
        ))
        self.entries = entries
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
