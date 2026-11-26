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
/// every other video in a column beside it. Your preview can float or join
/// the other tiles.
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
    @State private var copyRequest: CopyRequest?
    @State private var showsPeople = false
    @State private var showsInvitations = false
    @State private var showsActivities = false
    @State private var activityDrafts = CallActivityDrafts()
    @State private var showsChat = false
    @State private var reactionFailed = false
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
        _stageSelection =
            State(initialValue: CallStageSelection(layoutPreferences: actions.layoutPreferences))
    }

    public var body: some View {
        ZStack {
            CallBackdrop(photo: person?.avatarURL)
            if !stageVideos.isEmpty {
                CallVideoStage(
                    videos: stageVideos, roster: roster,
                    preview: selfViewSurface == .grid ? presentedPreview : nil,
                    ownHandRaised: actions.handRaised == true,
                    trailingColumn: trailingColumn,
                    selection: $stageSelection, saveLayout: actions.saveLayoutPreferences
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
        .overlay {
            CallVideoOverlays(
                selfPreview: floatingSelfView, ownHandRaised: actions.handRaised == true,
                share: sharingPreview, alongside: alongsideVideos,
                roster: roster, width: trailingTileWidth, selection: $stageSelection,
                saveLayout: actions.saveLayoutPreferences
            )
        }
        .modifier(CallFrame(isVideo: video != nil))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.sceneImageLoader, actions.imageLoader)
        .animation(.smooth(duration: 0.35), value: animationKey)
        .task(id: copyRequest?.id) {
            guard let request = copyRequest, request.call == call.id, copyState == .collecting else { return }
            let copied = await request.run()
            guard !Task.isCancelled, copyRequest?.id == request.id else { return }
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
        .modifier(CallActivityOverlay(
            callID: call.id, state: call.phase.isTerminal ? nil : actions.activities?.state
        ))
        .modifier(CallReactionFailureExpiry(failed: $reactionFailed))
        .sheet(isPresented: $showsInvitations) {
            if let invitations = actions.invitations {
                CallInvitePeople(actions: invitations)
            }
        }
        .onChange(of: participants, initial: true) { _, people in
            stageSelection.observeParticipants(people)
        }
        .onChange(of: video?.croppedPreview != nil, initial: true) { _, supported in
            stageSelection.supportsSelfCrop = supported
        }
        .onChange(of: call.phase.isTerminal) { _, terminal in
            if terminal {
                copyRequest = nil
                copyState = .idle
                showsInvitations = false; showsChat = false; showsActivities = false
                activityDrafts = CallActivityDrafts()
            }
        }
        .onChange(of: call.id) {
            copyRequest = nil
            copyState = .idle
            showsActivities = false
            activityDrafts = CallActivityDrafts()
            showsPeople = false
            showsInvitations = false
            showsChat = false
            reactionFailed = false
            stageSelection = CallStageSelection(layoutPreferences: actions.layoutPreferences)
            stageSelection.supportsSelfCrop = video?.croppedPreview != nil
            stageSelection.observeParticipants(participants)
        }
        .onChange(of: receivePreferenceUpdate, initial: true) { old, current in
            guard old.call == current.call, let binding = video?.receivePreferences,
                  binding.id == current.media else { return }
            binding.update(current.preferences)
        }
    }
}

extension AudioCallView {
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
                isPreparingMeeting: actions.meetingPreparation != nil,
                preparationPreview: actions.meetingPreparation?.cameraPreview?.content,
                showPeople: { showsPeople = true }
            )
        }
    }

    @ViewBuilder private var controls: some View {
        if let preparation = actions.meetingPreparation {
            CallMeetingPreparationControls(preparation: preparation)
        } else if call.phase == .incoming {
            CallAnswerControls(
                decline: actions.decline, accept: actions.accept, endsOtherCall: actions.endsOtherCall
            )
        } else if call.phase.isTerminal {
            CallFinishedControls(
                callBack: actions.callBack, returnToMeeting: actions.returnToMeeting, close: actions.close,
                diagnostics: diagnostics
            )
        } else {
            VStack(spacing: 12) {
                CallCaptionLabel(call: call, state: actions.activities?.state).id(call.id)
                CallWaitingRoomGuestMessages(
                    messages: call.admission == .waitingRoom ? actions.waitingRoomMessages : nil
                )
                ForEach(notices) { CallNoticeView(notice: $0) }
                if call.phase == .connected {
                    CallHandFeedback(
                        scene: actions.activities, participants: participants,
                        gestureProgress: actions.handGestureProgress, showsPeople: $showsPeople
                    ).id(call.id)
                }
                CallControlBar(
                    call: call, actions: actions, devices: devices, camera: camera,
                    screenSharing: screenSharing, diagnostics: diagnostics,
                    roster: roster, pinTargets: participants, showsPeople: $showsPeople,
                    stageSelection: video == nil ? nil : $stageSelection, layoutVideos: pinCandidates,
                    showsInvitations: $showsInvitations, showsActivities: $showsActivities,
                    showsChat: $showsChat,
                    react: CallReactionSender.action(for: actions.activities, failed: $reactionFailed)
                )
            }
        }
    }

    private var liveScreen: AnyView? {
        call.phase.isTerminal ? nil : screenPreview
    }

    private var selfViewSurface: CallSelfViewSurface {
        stageSelection.selfViewSurface(in: stageVideos)
    }

    private var floatingSelfView: AnyView? {
        selfViewSurface.isFloating ? presentedPreview : nil
    }

    private var presentedPreview: AnyView? {
        guard !stageSelection.hidesSelf, !call.phase.isTerminal else { return nil }
        if stageSelection.layoutPreferences.selfView.cropped, let preview = video?.croppedPreview {
            return preview
        }
        if let preview = video?.preview {
            return preview
        }
        if call.isConversationCall, call.phase == .connected, video != nil,
           !stageSelection.layoutPreferences.hidesTilesWithoutVideo {
            return AnyView(CallParticipantPlaceholder(name: "You"))
        }
        return nil
    }

    private var stageVideos: [CallRemoteVideo] {
        stageSelection.visibleVideos(from: pinCandidates)
    }

    private var receivePreferenceUpdate: CallVideoPreferenceUpdate {
        CallVideoPreferenceUpdate(
            call: call.id, media: video?.receivePreferences?.id,
            preferences: call.phase.isTerminal ? CallVideoPreferences() : stageSelection.receivePreferences
        )
    }

    private var pinCandidates: [CallRemoteVideo] {
        guard video != nil, !call.phase.isTerminal else { return [] }
        return CallStageSelection.videos(video?.remotes ?? [], roster: roster, participants: participants)
    }

    private var alongsideVideos: [CallRemoteVideo] {
        let others = stageSelection.filmstrip(in: stageVideos)
        if selfViewSurface == .filmstrip, let preview = presentedPreview {
            return others + [CallVideoStage.selfTile(preview, handRaised: actions.handRaised == true)]
        }
        return others
    }

    private var sharingPreview: CallSharingPreview? {
        guard video != nil, let liveScreen else { return nil }
        return CallSharingPreview(
            content: liveScreen, width: trailingTileWidth,
            sharesSound: screenSharing?.sharesSound == true, stop: stopSharing
        )
    }

    private var trailingColumn: CGFloat {
        if !alongsideVideos.isEmpty || sharingPreview != nil {
            return trailingTileWidth + 32
        }
        guard floatingSelfView != nil, stageSelection.layoutPreferences.selfView.corner == .topTrailing
        else { return 0 }
        return (stageSelection.minimizesSelf ? CallVideoOverlays.minimizedSize : trailingTileWidth) + 32
    }

    private var trailingTileWidth: CGFloat {
        stageSelection.presentationIsEnlarged(in: stageVideos) ? CallLayout
            .enlargedPresentationTile : CallLayout.tile
    }

    /// Joined devices for the People popover and video stage.
    private var roster: [CallRosterEntry]? {
        guard !call.phase.isTerminal, call.isConversationCall || actions.hasHandControls else { return nil }
        return CallRoster.entries(participants)
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
        let activities = actions.activities?.state
        var notices = AudioCallPresentation.notices(
            phase: call.phase, devices: devices, camera: camera, screenSharing: screenSharing,
            microphoneRestricted: actions.microphoneRestricted
        )
        if let closing = AudioCallPresentation.breakoutClosingNotice(
            phase: call.phase,
            activities: activities
        ) {
            notices.append(closing)
        }
        notices += CallArtifactPresentation.notices(for: activities?.artifacts ?? [])
        if reactionFailed {
            notices.append(CallNotice(id: "reaction", text: CallActivityCopy.reactionFailed, kind: .warning))
        }
        if let feedback = copyState.notice {
            notices.append(feedback)
        }
        return notices
    }

    private var diagnostics: CallDiagnosticsItem? {
        guard let copyDiagnostics = actions.copyDiagnostics else { return nil }
        return CallDiagnosticsItem(state: copyState) {
            copyRequest = CopyRequest(call: call.id, run: copyDiagnostics)
            copyState = .collecting
        }
    }

    private var animationKey: CallAnimationKey {
        CallAnimationKey(
            phase: call.phase, isMuted: call.isMuted,
            remoteMuted: AudioCallPresentation.showsRemoteMuted(call),
            remotes: stageVideos.map(\.id), preview: presentedPreview != nil,
            screen: liveScreen != nil, notices: notices.map(\.id), sharing: screenSharing?.phase,
            camera: camera.map { [$0.isOn, $0.isUpdating] },
            roster: roster?.map { [$0.id.uuidString, String(describing: $0.microphoneMuted)] }
        )
    }
}

private struct CopyRequest {
    let id = UUID()
    let call: UUID
    let run: () async -> Bool
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
