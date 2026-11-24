import ChatKit
import SwiftUI

/// Call controls are callbacks so the same window can serve any call service.
@MainActor
public struct AudioCallActions {
    public var imageLoader: SceneImageLoader?
    public var layoutPreferences = CallLayoutPreferences()
    public var saveLayoutPreferences: ((CallLayoutPreferences) -> Void)?
    /// Which account the call is on, while several are connected; `nil` with one.
    public var accountLabel: String?
    /// A ring that another account's call stands in the way of: Accept
    /// becomes End Call and Answer.
    public var endsOtherCall = false
    public var activities: CallActivitiesScene?
    public var chat: CallChatScene?
    public var invitations: CallInvitationActions?
    public var handRaised: Bool?
    public var isUpdatingHand = false
    public var microphoneRestricted = false
    public var toggleHandRaised: (() -> Void)?
    public var handGesture: CallHandGestureActions?
    public var handGestureProgress: Double?
    public var meetingPreparation: CallMeetingPreparation?
    public var meetingURL: URL?
    public var copyMeetingLink: (() -> Void)?
    public var meetingDetails: CallMeetingDetails?
    public var waitingRoomMessages: [CallMeetingMessage]?
    public var toggleScreenSharing: (() -> Void)?
    /// Starts sharing the screen with the Mac's sound. **Optional**: only a
    /// host that can send sound supplies it, and `nil` offers no such choice.
    public var shareScreenWithSound: (() -> Void)?
    public var toggleCamera: (() -> Void)?
    public var selectCamera: ((String) -> Void)?
    public var selectMicrophone: ((String) -> Void)?
    public var selectSpeaker: ((String) -> Void)?
    public var microphoneLevel: CallMicrophoneLevelAction?
    public var speakerTest: CallSpeakerTestAction?
    public var openVideoEffects: (() -> Void)?
    public var openMicrophoneModes: (() -> Void)?
    /// Starts a new call to the same person; offered only once a call has finished.
    public var callBack: (() -> Void)?
    public var returnToMeeting: (() -> Void)?
    /// Closes the window of a finished call.
    public var close: (() -> Void)?
    public var accept: () -> Void
    public var decline: () -> Void
    public var toggleMute: () -> Void
    public var hangUp: () -> Void
    /// Optional host-owned collection and copying; false reports unavailable.
    public var copyDiagnostics: (() async -> Bool)?

    var hasHandControls: Bool {
        toggleHandRaised != nil || activities?.state.availableActions.contains("lowerParticipantHand") == true
    }

    public init(
        accept: @escaping () -> Void,
        decline: @escaping () -> Void,
        toggleMute: @escaping () -> Void,
        hangUp: @escaping () -> Void,
        copyDiagnostics: (() async -> Bool)? = nil,
        selectMicrophone: ((String) -> Void)? = nil,
        selectSpeaker: ((String) -> Void)? = nil,
        toggleCamera: (() -> Void)? = nil,
        selectCamera: ((String) -> Void)? = nil,
        toggleScreenSharing: (() -> Void)? = nil,
        callBack: (() -> Void)? = nil,
        close: (() -> Void)? = nil
    ) {
        self.toggleScreenSharing = toggleScreenSharing
        self.toggleCamera = toggleCamera
        self.selectCamera = selectCamera
        self.selectMicrophone = selectMicrophone
        self.selectSpeaker = selectSpeaker
        self.callBack = callBack
        self.close = close
        self.accept = accept
        self.decline = decline
        self.toggleMute = toggleMute
        self.hangUp = hangUp
        self.copyDiagnostics = copyDiagnostics
    }
}

@MainActor
public struct CallHandGestureActions {
    public let isEnabled: Bool
    public let setEnabled: @MainActor @Sendable (Bool) -> Void
    public let raise: () -> Void

    public init(
        isEnabled: Bool, setEnabled: @escaping @MainActor @Sendable (Bool) -> Void,
        raise: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.raise = raise
    }
}

/// When the call connected and when it finished. The host keeps these, so the
/// duration survives the window's content being rebuilt.
public struct CallTiming: Equatable, Sendable {
    public var connectedAt: Date?
    public var endedAt: Date?

    public init(connectedAt: Date? = nil, endedAt: Date? = nil) {
        self.connectedAt = connectedAt
        self.endedAt = endedAt
    }
}
