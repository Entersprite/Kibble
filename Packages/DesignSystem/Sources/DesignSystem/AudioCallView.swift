import ChatKit
import SwiftUI

/// Call controls are callbacks so the same window can serve any call service.
@MainActor
public struct AudioCallActions {
    public var imageLoader: SceneImageLoader?
    /// Which account the call is on, while several are connected; `nil` with one.
    public var accountLabel: String?
    /// A ring that another account's call stands in the way of: Accept
    /// becomes End Call and Answer.
    public var endsOtherCall = false
    public var toggleScreenSharing: (() -> Void)?
    /// Starts sharing the screen with the Mac's sound. **Optional**: only a
    /// host that can send sound supplies it, and `nil` offers no such choice.
    public var shareScreenWithSound: (() -> Void)?
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

/// The one window for incoming, outgoing and video calls, with one person or
/// in a group or space.
///
/// A dark stage with the person, or the conversation, in the middle and round
/// glass controls floating at the bottom. A conversation call lists who else
/// is in it under its name, as the provider reports their devices. Passing
/// `video` switches to the stage a video call uses: one video fills the
/// window, several share it in a grid, and a shared screen fills it with
/// every other video in a column beside it; your camera sits in a corner.
/// The host decides when that happens and how big the window is.
/// `screenPreview` is what you are sharing: it takes the picture's place in
/// the audio layout and a corner tile in the video layout.
///
/// The backdrop and the main video run under the transparent titlebar, to
/// the window's edges; everything else keeps to the safe area.
public struct AudioCallView: View {
    private let call: AudioCallSession
    private let actions: AudioCallActions
    private let person: Member?
    private let conversation: Conversation?
    private let participants: [CallParticipantDevice]?
    private let timing: CallTiming
    private let devices: CallAudioDevices?
    private let screenSharing: CallScreenShareState?
    private let camera: CallCameraState?
    private let video: CallVideoContent?
    private let screenPreview: AnyView?
    @State private var copyState = AudioCallCopyState.idle
    @State private var requestedCall: UUID?
    @State private var copyRequest = 0
    @State private var showsPeople = false

    public init(
        call: AudioCallSession,
        actions: AudioCallActions,
        person: Member? = nil,
        conversation: Conversation? = nil,
        participants: [CallParticipantDevice]? = nil,
        timing: CallTiming = CallTiming(),
        devices: CallAudioDevices? = nil,
        camera: CallCameraState? = nil,
        video: CallVideoContent? = nil,
        screenSharing: CallScreenShareState? = nil,
        screenPreview: AnyView? = nil
    ) {
        self.call = call
        self.actions = actions
        self.person = person
        self.conversation = conversation
        self.participants = participants
        self.timing = timing
        self.devices = devices
        self.camera = camera
        self.video = video
        self.screenSharing = screenSharing
        self.screenPreview = screenPreview
    }

    public var body: some View {
        ZStack {
            CallBackdrop(photo: person?.avatarURL)
            if let live = liveVideo, !live.remotes.isEmpty {
                CallVideoStage(
                    videos: live.remotes, roster: roster, preview: isGrid ? live.preview : nil,
                    trailingColumn: CallLayout.tile + 32
                )
            }
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                if let screen = liveScreen, video == nil {
                    CallSharingHeader(
                        call: call, timing: timing, content: screen,
                        sharesSound: screenSharing?.sharesSound == true, stop: stopSharing
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if liveVideo?.remotes.isEmpty != false {
                    header
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                Spacer(minLength: 20)
                controls
            }
            .padding(.top, CallLayout.titlebarGap)
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
            // The audio layout's column keeps the compact width in a larger
            // window, a full-screen one, while the backdrop fills it.
            .frame(width: video == nil ? CallLayout.compact.width : nil)
        }
        // The only text in the titlebar's band, so it alone reaches into it.
        .overlay(alignment: .top) {
            if let live = liveVideo, !live.remotes.isEmpty {
                let main = CallStageLayout.main(of: live.remotes)
                CallVideoTitle(
                    call: call, timing: timing, isScreen: main?.isScreen == true,
                    presenter: call.isConversationCall && main?.isScreen == true ? main?.label : nil
                )
                .padding(.top, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if let preview = liveVideo?.preview, !isGrid {
                    CallSelfView(content: preview)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                }
                if video != nil, let screen = liveScreen {
                    CallSharingPreview(
                        content: screen, width: CallLayout.tile,
                        sharesSound: screenSharing?.sharesSound == true,
                        stop: stopSharing
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                }
                let alongside = CallStageLayout.alongside(liveVideo?.remotes ?? [])
                if !alongside.isEmpty {
                    CallVideoFilmstrip(videos: alongside, roster: roster, width: CallLayout.tile)
                        // Clear of the controls floating at the bottom.
                        .padding(.bottom, 88)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.top, CallLayout.titlebarGap)
            .padding(.trailing, 16)
        }
        .modifier(CallFrame(isVideo: video != nil))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.sceneImageLoader, actions.imageLoader)
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
            showsPeople = false
        }
    }

    /// The person's picture and name, or the conversation's and who is in it.
    @ViewBuilder private var header: some View {
        if let member = call.recipient?.memberID {
            CallPersonHeader(
                call: call, member: member, directory: directory(member), timing: timing,
                avatarSize: video == nil ? 104 : 128, accountLabel: actions.accountLabel
            )
        } else {
            CallConversationHeader(
                call: call, conversation: conversation, roster: roster, timing: timing,
                accountLabel: actions.accountLabel, avatarSize: video == nil ? 88 : 112,
                showPeople: { showsPeople = true }
            )
        }
    }

    @ViewBuilder private var controls: some View {
        if call.phase == .incoming {
            CallAnswerControls(
                decline: actions.decline, accept: actions.accept, endsOtherCall: actions.endsOtherCall
            )
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
                    screenSharing: screenSharing, diagnostics: diagnostics,
                    roster: roster, showsPeople: $showsPeople
                )
            }
        }
    }

    /// Video is drawn only while the call is live; a finished video call
    /// keeps the stage's size and shows the person again.
    private var liveVideo: CallVideoContent? {
        call.phase.isTerminal ? nil : video
    }

    private var liveScreen: AnyView? {
        call.phase.isTerminal ? nil : screenPreview
    }

    /// Several cameras share the stage, your own among them.
    private var isGrid: Bool {
        if case .grid = CallStageLayout.of(liveVideo?.remotes ?? []) {
            return true
        }
        return false
    }

    /// Who else is in a conversation call; a call with one person shows the
    /// person instead, with the mute the snapshot itself reports.
    private var roster: [CallRosterEntry]? {
        call.isConversationCall && !call.phase.isTerminal ? CallRoster.entries(participants) : nil
    }

    /// The preview's own Stop Sharing, offered once sharing has started.
    private var stopSharing: (() -> Void)? {
        screenSharing?.phase == .sharing ? actions.toggleScreenSharing : nil
    }

    /// The directory `Avatar` reads: the person's own entry, or a stand-in
    /// built from the call's name so initials still show.
    private func directory(_ id: Member.ID) -> [Member.ID: Member] {
        [id: person ?? Member(id: id, kind: .human, displayName: call.displayName)]
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
            remoteMuted: AudioCallPresentation.showsRemoteMuted(call),
            remotes: liveVideo?.remotes.map(\.id) ?? [], preview: liveVideo?.preview != nil,
            screen: liveScreen != nil, notices: notices.map(\.id), sharing: screenSharing?.phase,
            camera: camera.map { [$0.isOn, $0.isUpdating] },
            roster: roster?.map { [$0.id.uuidString, String(describing: $0.microphoneMuted)] }
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
    let remoteMuted: Bool
    let remotes: [Int]
    let preview: Bool
    let screen: Bool
    let notices: [String]
    let sharing: CallScreenShareState.Phase?
    let camera: [Bool]?
    let roster: [[String]]?
}

/// Sizes the call window's two layouts share with the host.
public enum CallLayout {
    /// The audio window. Its height grows only if a long notice needs it.
    public static let compact = CGSize(width: 360, height: 460)
    /// The size a call window grows to when video first appears.
    public static let video = CGSize(width: 760, height: 480)
    /// The smallest a video call window can be resized to.
    public static let videoMinimum = CGSize(width: 480, height: 360)
    /// Space between the stage's content and the transparent titlebar, whose
    /// window buttons the content keeps clear of through the safe area. Under
    /// a 32-point titlebar that is 46 points from the window's top; in full
    /// screen, where the titlebar is hidden, the content moves up.
    static let titlebarGap: CGFloat = 14
    /// Your camera, your shared screen and the videos beside a shared screen.
    static let tile: CGFloat = 192
    static let button: CGFloat = 46
    static let answerButton: CGFloat = 62
}

/// Both layouts fill the window, so either can go full screen. The audio
/// layout's ideal size is still the compact one, which is what the host sizes
/// its window to; its column keeps that width (`body`).
private struct CallFrame: ViewModifier {
    let isVideo: Bool

    func body(content: Content) -> some View {
        let minimum = isVideo ? CallLayout.videoMinimum : CallLayout.compact
        content.frame(
            minWidth: minimum.width, maxWidth: .infinity,
            minHeight: minimum.height, maxHeight: .infinity
        )
    }
}
