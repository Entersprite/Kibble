import ChatKit
import SwiftUI

/// Call controls are callbacks so the same window can serve any call service.
@MainActor
public struct AudioCallActions {
    public var toggleScreenSharing: (() -> Void)?
    public var toggleCamera: (() -> Void)?
    public var selectCamera: ((String) -> Void)?
    public var selectMicrophone: ((String) -> Void)?
    public var selectSpeaker: ((String) -> Void)?
    /// Starts a new call to the same person; offered only once a call has finished.
    public var callBack: (() -> Void)?
    /// Closes the window of a finished call.
    public var close: (() -> Void)?
    public var accept: () -> Void
    public var decline: () -> Void
    public var toggleMute: () -> Void
    public var hangUp: () -> Void
    /// Optional host-owned collection and copying; false reports unavailable.
    public var copyDiagnostics: (() async -> Bool)?

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

/// Video renderers supplied by the host. The shared layout decides where each
/// one goes; the platform media engine draws inside them.
public struct CallVideoContent {
    /// The other person's camera or shared screen, present only while showing.
    public var remote: AnyView?
    public var remoteIsScreen: Bool
    /// Your own camera, present only while it is on.
    public var preview: AnyView?

    public init(remote: AnyView? = nil, remoteIsScreen: Bool = false, preview: AnyView? = nil) {
        self.remote = remote
        self.remoteIsScreen = remoteIsScreen
        self.preview = preview
    }

    public var hasVideo: Bool {
        remote != nil || preview != nil
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

/// The one window for incoming, outgoing and video calls.
///
/// A dark stage with the person in the middle and round glass controls
/// floating at the bottom. Passing `video` switches to the stage a video call
/// uses: the other person's video fills the window and your camera sits in a
/// corner. The host decides when that happens and how big the window is.
public struct AudioCallView: View {
    private let call: AudioCallSnapshot
    private let actions: AudioCallActions
    private let person: Member?
    private let timing: CallTiming
    private let devices: CallAudioDevices?
    private let screenSharing: CallScreenShareState?
    private let camera: CallCameraState?
    private let video: CallVideoContent?
    @State private var copyState = AudioCallCopyState.idle
    @State private var requestedCall: UUID?
    @State private var copyRequest = 0

    public init(
        call: AudioCallSnapshot,
        actions: AudioCallActions,
        person: Member? = nil,
        timing: CallTiming = CallTiming(),
        devices: CallAudioDevices? = nil,
        camera: CallCameraState? = nil,
        video: CallVideoContent? = nil,
        screenSharing: CallScreenShareState? = nil
    ) {
        self.call = call
        self.actions = actions
        self.person = person
        self.timing = timing
        self.devices = devices
        self.camera = camera
        self.video = video
        self.screenSharing = screenSharing
    }

    public var body: some View {
        ZStack {
            CallBackdrop(photo: person?.avatarURL)
            if let live = liveVideo, let remote = live.remote {
                CallRemoteStage(content: remote, isScreen: live.remoteIsScreen)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                if liveVideo?.remote == nil {
                    CallPersonHeader(
                        call: call, directory: directory, timing: timing,
                        avatarSize: video == nil ? 104 : 128
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                Spacer(minLength: 20)
                controls
            }
            .padding(.top, CallLayout.titlebarClearance)
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .overlay(alignment: .top) {
            if let live = liveVideo, live.remote != nil {
                CallVideoTitle(call: call, timing: timing, isScreen: live.remoteIsScreen)
                    .padding(.top, 9)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let preview = liveVideo?.preview {
                CallSelfView(content: preview)
                    .padding(.top, CallLayout.titlebarClearance)
                    .padding(.trailing, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
            }
        }
        .modifier(CallFrame(isVideo: video != nil))
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.35), value: animationKey)
        .task(id: CopyRequest(call: call.id, sequence: copyRequest)) {
            guard requestedCall == call.id, copyState == .collecting,
                  let copyDiagnostics = actions.copyDiagnostics else { return }
            let copied = await copyDiagnostics()
            guard !Task.isCancelled, requestedCall == call.id else { return }
            copyState = copied ? .copied : .unavailable
        }
        .task(id: copyState) {
            guard copyState == .copied || copyState == .unavailable else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                copyState = .idle
            }
        }
        .onChange(of: call.id) {
            requestedCall = nil
            copyState = .idle
        }
    }

    @ViewBuilder private var controls: some View {
        if call.phase == .incoming {
            CallAnswerControls(decline: actions.decline, accept: actions.accept)
        } else if call.phase.isTerminal {
            CallFinishedControls(
                callBack: actions.callBack, close: actions.close,
                diagnostics: diagnostics
            )
        } else {
            VStack(spacing: 12) {
                ForEach(notices) { CallNoticeView(notice: $0) }
                CallControlBar(
                    call: call, actions: actions, devices: devices, camera: camera,
                    screenSharing: screenSharing, diagnostics: diagnostics
                )
            }
        }
    }

    /// Video is drawn only while the call is live; a finished video call
    /// keeps the stage's size and shows the person again.
    private var liveVideo: CallVideoContent? {
        call.phase.isTerminal ? nil : video
    }

    /// The directory `Avatar` reads: the person's own entry, or a stand-in
    /// built from the call's name so initials still show.
    private var directory: [Member.ID: Member] {
        let id = call.recipient.memberID
        return [id: person ?? Member(id: id, kind: .human, displayName: call.recipient.displayName)]
    }

    private var notices: [CallNotice] {
        var notices = AudioCallPresentation.notices(
            phase: call.phase, devices: devices, camera: camera, screenSharing: screenSharing
        )
        if let feedback = copyState.notice {
            notices.append(feedback)
        }
        return notices
    }

    private var diagnostics: CallDiagnosticsItem? {
        guard actions.copyDiagnostics != nil else { return nil }
        return CallDiagnosticsItem(state: copyState) {
            requestedCall = call.id
            copyState = .collecting
            copyRequest += 1
        }
    }

    private var animationKey: CallAnimationKey {
        CallAnimationKey(
            phase: call.phase, isMuted: call.isMuted,
            remote: liveVideo?.remote != nil, preview: liveVideo?.preview != nil,
            notices: notices.map(\.id), sharing: screenSharing?.phase,
            camera: camera.map { [$0.isOn, $0.isUpdating] }
        )
    }

    private struct CopyRequest: Hashable {
        let call: UUID
        let sequence: Int
    }
}

/// Everything whose change should animate the stage.
private struct CallAnimationKey: Equatable {
    let phase: AudioCallPhase
    let isMuted: Bool
    let remote: Bool
    let preview: Bool
    let notices: [String]
    let sharing: CallScreenShareState.Phase?
    let camera: [Bool]?
}

/// Sizes the call window's two layouts share with the host.
public enum CallLayout {
    /// The audio window. Its height grows only if a long notice needs it.
    public static let compact = CGSize(width: 360, height: 460)
    /// The size a call window grows to when video first appears.
    public static let video = CGSize(width: 760, height: 480)
    /// The smallest a video call window can be resized to.
    public static let videoMinimum = CGSize(width: 480, height: 360)
    /// Clears the transparent titlebar and its window buttons.
    static let titlebarClearance: CGFloat = 46
    static let button: CGFloat = 46
    static let answerButton: CGFloat = 62
}

/// The audio layout has a fixed width; the video layout fills the window.
private struct CallFrame: ViewModifier {
    let isVideo: Bool

    func body(content: Content) -> some View {
        if isVideo {
            content.frame(
                minWidth: CallLayout.videoMinimum.width, maxWidth: .infinity,
                minHeight: CallLayout.videoMinimum.height, maxHeight: .infinity
            )
        } else {
            content
                .frame(width: CallLayout.compact.width)
                .frame(minHeight: CallLayout.compact.height)
        }
    }
}

enum AudioCallPresentation {
    static func status(for phase: AudioCallPhase) -> String {
        switch phase {
        case .incoming: "Incoming call"
        case .connecting: "Connecting…"
        case .ringing: "Ringing…"
        case .connected: "Connected"
        case .declined: "Decline sent"
        case .failed: "Call failed"
        case .ended: "Call ended"
        case .unknown: "Call unavailable"
        }
    }

    static func canMute(_ phase: AudioCallPhase) -> Bool {
        phase == .ringing || phase == .connected
    }

    static func canHangUp(_ phase: AudioCallPhase) -> Bool {
        phase == .connecting || phase == .ringing || phase == .connected
    }

    /// The halo pulses while the call is waiting for someone to answer.
    static func isWaiting(_ phase: AudioCallPhase) -> Bool {
        phase == .incoming || phase == .connecting || phase == .ringing
    }

    static func failureMessage(for call: AudioCallSnapshot) -> String? {
        if let message = call.failureMessage {
            return message
        }
        return call.phase == .failed ? "The call couldn't be completed. Please try again." : nil
    }

    /// "4:12", or "1:04:12" past an hour.
    static func duration(_ seconds: TimeInterval) -> String {
        let value = Duration.seconds(max(0, Int(seconds)))
        return seconds >= 3600
            ? value.formatted(.time(pattern: .hourMinuteSecond))
            : value.formatted(.time(pattern: .minuteSecond))
    }

    /// Device and sharing messages, shown above the controls only while the
    /// controls they belong to are usable.
    static func notices(
        phase: AudioCallPhase, devices: CallAudioDevices?, camera: CallCameraState?,
        screenSharing: CallScreenShareState?
    ) -> [CallNotice] {
        var notices: [CallNotice] = []
        if !phase.isTerminal, let notice = devices?.notice {
            notices.append(CallNotice(id: "audio", text: notice, kind: .warning))
        }
        guard canMute(phase) else { return notices }
        if let notice = camera?.notice {
            notices.append(CallNotice(id: "camera", text: notice, kind: .warning))
        }
        if screenSharing?.phase == .preparing {
            notices.append(CallNotice(
                id: "share-picker", text: "Choose a window or display to share.", kind: .info
            ))
        }
        if let notice = screenSharing?.notice {
            notices.append(CallNotice(id: "share", text: notice, kind: .warning))
        }
        return notices
    }
}

/// Collection feedback belongs to presentation; diagnostics contents stay in
/// the host and never enter the call view's state.
enum AudioCallCopyState {
    case idle, collecting, copied, unavailable

    var title: String {
        switch self {
        case .idle: "Copy Diagnostics"
        case .collecting: "Collecting…"
        case .copied: "Copied"
        case .unavailable: "Unavailable"
        }
    }

    /// What a live call shows above its controls after the menu item is chosen.
    var notice: CallNotice? {
        switch self {
        case .idle: nil
        case .collecting: CallNotice(id: "diagnostics", text: "Collecting diagnostics…", kind: .progress)
        case .copied: CallNotice(id: "diagnostics", text: "Diagnostics copied", kind: .success)
        case .unavailable: CallNotice(id: "diagnostics", text: "Diagnostics unavailable", kind: .warning)
        }
    }
}
