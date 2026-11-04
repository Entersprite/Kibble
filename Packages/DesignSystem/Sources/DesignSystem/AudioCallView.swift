import ChatKit
import SwiftUI

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
    @State private var showsInvitations = false
    @State private var showsActivities = false
    @State private var activityDrafts = CallActivityDrafts()
    @State private var showsChat = false
    @State private var stageSelection = CallStageSelection()

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
            if !stageVideos.isEmpty {
                CallVideoStage(
                    videos: stageVideos, roster: roster,
                    preview: isGrid ? presentedPreview : nil,
                    trailingColumn: CallLayout.tile + 32, selection: stageSelection, pin: pin
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
                } else if stageVideos.isEmpty {
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
            if !stageVideos.isEmpty {
                let main = stageSelection.main(in: stageVideos)
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
                if let preview = presentedPreview, !isGrid {
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
                let alongside = alongsideVideos
                if !alongside.isEmpty {
                    CallVideoFilmstrip(
                        videos: alongside,
                        roster: roster,
                        width: CallLayout.tile,
                        selection: stageSelection,
                        pin: pin
                    )
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
        .sheet(isPresented: $showsActivities) {
            if let activities = actions.activities {
                CallActivitiesView(scene: activities, drafts: $activityDrafts)
            }
        }
        .modifier(CallActivityOverlay(state: actions.activities?.state))
        .popover(isPresented: $showsChat) {
            if let chat = actions.chat {
                CallChatView(scene: chat)
            }
        }
        .sheet(isPresented: $showsInvitations) {
            if let invitations = actions.invitations {
                CallInvitePeople(actions: invitations)
            }
        }
        .onChange(of: roster?.first(where: \.isSpeaking)?.id) { _, speaker in
            if let speaker {
                stageSelection.activeSpeaker = speaker
            }
        }
        .onChange(of: call.phase.isTerminal) { _, terminal in
            if terminal {
                showsInvitations = false; showsChat = false; showsActivities = false
                activityDrafts = CallActivityDrafts()
            }
        }
        .onChange(of: call.id) {
            requestedCall = nil
            copyState = .idle
            showsActivities = false
            activityDrafts = CallActivityDrafts()
            showsPeople = false
            showsInvitations = false
            showsChat = false
            stageSelection = CallStageSelection()
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
                    roster: roster, showsPeople: $showsPeople,
                    stageSelection: video == nil ? nil : $stageSelection, layoutVideos: stageVideos,
                    showsInvitations: $showsInvitations, showsActivities: $showsActivities,
                    showsChat: $showsChat
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
        if case .grid = stageSelection.stage(in: stageVideos) {
            return true
        }
        return false
    }

    private var presentedPreview: AnyView? {
        guard !stageSelection.hidesSelf, !call.phase.isTerminal else { return nil }
        if let preview = liveVideo?.preview {
            return preview
        }
        if call.isConversationCall, call.phase == .connected, video != nil {
            return AnyView(CallParticipantPlaceholder(name: "You"))
        }
        return nil
    }

    private var stageVideos: [CallRemoteVideo] {
        guard video != nil, !call.phase.isTerminal else { return [] }
        return CallStageSelection.videos(liveVideo?.remotes ?? [], roster: roster)
    }

    private var alongsideVideos: [CallRemoteVideo] {
        guard stageSelection.stage(in: stageVideos) == .presentation,
              let main = stageSelection.main(in: stageVideos) else { return [] }
        return stageVideos.filter { $0.id != main.id }
    }

    private func pin(_ video: CallRemoteVideo) {
        let key = CallStageSelection.key(video)
        stageSelection.pinned = stageSelection.pinned == key ? nil : key
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
        for artifact in actions.activities?.state.artifacts ?? []
            where ["active", "starting"].contains(artifact.phase) {
            notices.append(CallNotice(
                id: "artifact/" + artifact.kind,
                text: artifact.kind
                    .capitalized +
                    (artifact.phase == "active" ? " is active" : " is starting"),
                kind: .info
            ))
        }
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
            remotes: liveVideo?.remotes.map(\.id) ?? [], preview: presentedPreview != nil,
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
