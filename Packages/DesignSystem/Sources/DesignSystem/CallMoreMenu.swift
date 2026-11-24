import Foundation
import SwiftUI

/// The meeting's reactions as one palette row at the top of the More menu,
/// the way a message's are in its context menu. A palette draws each cell's
/// picture and drops its title, so every emoji goes in as an `EmojiGlyph`
/// and keeps a title for VoiceOver.
struct CallReactionPalette: View {
    static let emoji = ["👍", "❤️", "😂", "😮", "👏", "🎉"]
    let react: (String) -> Void

    var body: some View {
        ControlGroup {
            ForEach(Self.emoji, id: \.self) { emoji in
                Button {
                    react(emoji)
                } label: {
                    Label {
                        Text("React \(emoji)")
                    } icon: {
                        if let glyph = EmojiGlyph.image(for: emoji) {
                            Image(decorative: glyph, scale: EmojiGlyph.scale)
                                .renderingMode(.original)
                        }
                    }
                }
            }
        }
        .controlGroupStyle(.palette)
    }
}

/// Everything a call offers beyond its round buttons, behind one control
/// rather than always on show.
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

    /// Sends a reaction; supplied only while the meeting takes them.
    var react: ((String) -> Void)?

    var hasContent: Bool {
        audio != nil || video != nil || diagnostics != nil || stageSelection != nil || react != nil
            || interactions?.toggleHandRaised != nil || interactions?.handGesture != nil
            || interactions?.meetingURL != nil || interactions?.meetingDetails != nil
            || interactions?.invitations != nil || interactions?.chat != nil
            || interactions?.activities != nil
    }

    /// What you do in the meeting comes first (a reaction, your hand), then
    /// its panels, its link and details, how the window lays it out, and last
    /// the devices. Each is a section of its own, so the menu reads in groups
    /// however much of it a call offers.
    var body: some View {
        Menu {
            Section {
                if let react {
                    CallReactionPalette(react: react)
                }
                if let interactions {
                    CallHandControls(actions: interactions)
                }
            }
            Section {
                if interactions?.chat != nil, let showsChat {
                    Button("Chat", systemImage: "bubble.left.and.bubble.right") {
                        showsChat.wrappedValue = true
                    }
                }
                if interactions?.activities != nil, let showsActivities {
                    Button("Meeting Activities…", systemImage: "square.grid.2x2") {
                        showsActivities.wrappedValue = true
                    }
                }
                if interactions?.invitations != nil, let showsInvitations {
                    Button("Invite People…", systemImage: "person.badge.plus") {
                        showsInvitations.wrappedValue = true
                    }
                }
            }
            if let interactions {
                Section {
                    if let details = interactions.meetingDetails {
                        Button("Meeting Details…", systemImage: "info.circle") {
                            requestedMeetingDetails = details.id
                        }
                    }
                    if let url = interactions.meetingURL {
                        if let copy = interactions.copyMeetingLink {
                            Button("Copy Meeting Link", systemImage: "link", action: copy)
                        }
                        ShareLink(item: url) {
                            Label("Share Meeting Link…", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            if let stageSelection {
                let save = interactions?.saveLayoutPreferences
                Section {
                    CallLayoutMenu(selection: stageSelection, videos: layoutVideos, save: save)
                }
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
