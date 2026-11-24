import Foundation
import SwiftUI

/// Devices and diagnostics, behind one control rather than pickers always on
/// show: the sections a menu bar's Video menu would hold.
struct CallMoreMenu: View {
    struct Audio {
        let devices: CallAudioDevices
        let selectMicrophone: (String) -> Void
        let selectSpeaker: (String) -> Void
    }

    struct Video {
        let camera: CallCameraState
        let select: (String) -> Void
    }

    let audio: Audio?
    let video: Video?
    let diagnostics: CallDiagnosticsItem?
    var stageSelection: Binding<CallStageSelection>?
    var layoutVideos: [CallRemoteVideo] = []
    var showsInvitations: Binding<Bool>?
    var showsActivities: Binding<Bool>?
    var showsChat: Binding<Bool>?
    var interactions: AudioCallActions?
    @State private var requestedMicrophoneLevel: UUID?
    @State private var requestedMeetingDetails: UUID?

    var hasContent: Bool {
        audio != nil || video != nil || diagnostics != nil || stageSelection != nil || interactions?
            .toggleHandRaised != nil || interactions?.meetingURL != nil || interactions?.meetingDetails != nil
            || interactions?
            .invitations != nil || interactions?.chat != nil || interactions?.activities != nil
    }

    var body: some View {
        Menu {
            if interactions?.activities != nil, let showsActivities {
                Button("Activities…", systemImage: "square.grid.2x2") { showsActivities.wrappedValue = true }
            }
            if interactions?.chat != nil, let showsChat {
                Button("Chat", systemImage: "bubble.left.and.bubble.right") { showsChat.wrappedValue = true }
            }
            if interactions?.invitations != nil, let showsInvitations {
                Button("Invite People…", systemImage: "person.badge.plus") {
                    showsInvitations.wrappedValue = true
                }
            }
            if let interactions {
                CallHandControls(actions: interactions)
                if let url = interactions.meetingURL {
                    if let copy = interactions.copyMeetingLink {
                        Button(
                            "Copy Meeting Link",
                            systemImage: "link",
                            action: copy
                        )
                    }
                    ShareLink(item: url) { Label("Share Meeting Link", systemImage: "square.and.arrow.up") }
                }
                if let details = interactions.meetingDetails {
                    Button("Meeting Details…", systemImage: "info.circle") {
                        requestedMeetingDetails = details.id
                    }
                }
            }
            if let stageSelection {
                let save = interactions?.saveLayoutPreferences
                CallLayoutMenu(selection: stageSelection, videos: layoutVideos, save: save)
            }
            if let audio {
                CallAudioDeviceSections(
                    devices: audio.devices, selectMicrophone: audio.selectMicrophone,
                    selectSpeaker: audio.selectSpeaker,
                    openMicrophoneModes: interactions?.openMicrophoneModes,
                    checkMicrophone: microphoneLevelAction,
                    speakerTest: interactions?.speakerTest
                )
            }
            if let video {
                CallCameraSection(
                    camera: video.camera, select: video.select,
                    openVideoEffects: interactions?.openVideoEffects
                )
            }
            if let diagnostics {
                Divider()
                Button("Copy Diagnostics", systemImage: "doc.on.clipboard", action: diagnostics.run)
                    .disabled(diagnostics.state == .collecting)
            }
        } label: {
            CallRoundFace(title: "More", symbol: "ellipsis", tone: .plain, size: CallLayout.button)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Call Options")
        .modifier(CallMicrophoneLevelPopover(
            action: interactions?.microphoneLevel, request: $requestedMicrophoneLevel
        ))
        .modifier(CallMeetingDetailsPopover(
            details: interactions?.meetingDetails, request: $requestedMeetingDetails
        ))
    }

    private var microphoneLevelAction: (() -> Void)? {
        guard let microphoneLevel = interactions?.microphoneLevel else { return nil }
        return { requestedMicrophoneLevel = microphoneLevel.id }
    }
}
