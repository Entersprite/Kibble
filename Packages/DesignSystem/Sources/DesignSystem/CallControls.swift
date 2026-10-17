import ChatKit
import SwiftUI

/// One round glass control. The glass is drawn by `glassEffect` on a plain
/// button rather than by the glass button styles, which pad an icon label to
/// a size of their own; a call bar needs every circle the same.
struct CallRoundButton: View {
    let title: String
    let symbol: String
    var tone = CallControlTone.plain
    var size = CallLayout.button
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CallRoundFace(title: title, symbol: symbol, tone: tone, size: size)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// What a round control is saying: white for a muted microphone, the accent
/// color while sharing, red to end and green to answer.
enum CallControlTone {
    case plain, highlighted, active, end, accept

    var glass: Glass {
        switch self {
        case .plain: .regular
        case .highlighted: .regular.tint(.white)
        case .active: .regular.tint(.accentColor)
        case .end: .regular.tint(.red)
        case .accept: .regular.tint(.green)
        }
    }

    var foreground: Color {
        self == .highlighted ? .black : .white
    }
}

struct CallRoundFace: View {
    let title: String
    let symbol: String
    let tone: CallControlTone
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .font(.system(size: (size * 0.39).rounded(), weight: .semibold))
            .foregroundStyle(tone.foreground)
            .opacity(isEnabled ? 1 : 0.35)
            .frame(width: size, height: size)
            .glassEffect(tone.glass.interactive(isEnabled), in: .circle)
            .contentShape(Circle())
    }
}

/// The controls of a live call: microphone, camera, sharing, the device menu
/// and End, in that order, as FaceTime orders them.
struct CallControlBar: View {
    let call: AudioCallSnapshot
    let actions: AudioCallActions
    let devices: CallAudioDevices?
    let camera: CallCameraState?
    let screenSharing: CallScreenShareState?
    let diagnostics: CallDiagnosticsItem?

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 12) {
                CallRoundButton(
                    title: call.isMuted ? "Unmute" : "Mute",
                    symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                    tone: call.isMuted ? .highlighted : .plain,
                    action: actions.toggleMute
                )
                .disabled(!canUseMedia)
                if canUseMedia, let camera, let toggle = actions.toggleCamera {
                    CallCameraButton(camera: camera, toggle: toggle)
                }
                if canUseMedia, let screenSharing, let toggle = actions.toggleScreenSharing {
                    CallScreenShareButton(state: screenSharing, toggle: toggle)
                }
                if menu.hasContent {
                    menu
                }
                CallRoundButton(
                    title: "End Call", symbol: "phone.down.fill", tone: .end, action: actions.hangUp
                )
                .disabled(!AudioCallPresentation.canHangUp(call.phase))
            }
        }
    }

    private var canUseMedia: Bool {
        AudioCallPresentation.canMute(call.phase)
    }

    private var menu: CallMoreMenu {
        var audio: CallMoreMenu.Audio?
        if let devices, let microphone = actions.selectMicrophone, let speaker = actions.selectSpeaker {
            audio = CallMoreMenu.Audio(devices: devices, selectMicrophone: microphone, selectSpeaker: speaker)
        }
        var video: CallMoreMenu.Video?
        if canUseMedia, let camera, let select = actions.selectCamera {
            video = CallMoreMenu.Video(camera: camera, select: select)
        }
        return CallMoreMenu(audio: audio, video: video, diagnostics: diagnostics)
    }
}

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

    var hasContent: Bool {
        audio != nil || video != nil || diagnostics != nil
    }

    var body: some View {
        Menu {
            if let audio {
                CallAudioDeviceSections(
                    devices: audio.devices, selectMicrophone: audio.selectMicrophone,
                    selectSpeaker: audio.selectSpeaker
                )
            }
            if let video {
                CallCameraSection(camera: video.camera, select: video.select)
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
    }
}

struct CallDiagnosticsItem {
    let state: AudioCallCopyState
    let run: () -> Void
}

/// Answer and decline, large and labelled, the way an incoming call is
/// answered on every Apple device.
struct CallAnswerControls: View {
    let decline: () -> Void
    let accept: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 64) {
                answer("Decline", symbol: "phone.down.fill", tone: .end, action: decline)
                answer("Accept", symbol: "phone.fill", tone: .accept, action: accept)
            }
        }
        .padding(.bottom, 4)
    }

    private func answer(
        _ title: String, symbol: String, tone: CallControlTone, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            CallRoundButton(
                title: title, symbol: symbol, tone: tone, size: CallLayout.answerButton, action: action
            )
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// What is left once a call is over: close the window or call again.
struct CallFinishedControls: View {
    let callBack: (() -> Void)?
    let close: (() -> Void)?
    let diagnostics: CallDiagnosticsItem?

    var body: some View {
        VStack(spacing: 16) {
            if callBack != nil || close != nil {
                HStack(spacing: 12) {
                    if let close {
                        Button("Close", action: close)
                            .buttonStyle(.glass)
                            .keyboardShortcut(.cancelAction)
                    }
                    if let callBack {
                        Button("Call Back", systemImage: "phone.fill", action: callBack)
                            .buttonStyle(.glassProminent)
                            .tint(.green)
                    }
                }
                .controlSize(.extraLarge)
            }
            if let diagnostics {
                Button(diagnostics.state.title, systemImage: "doc.on.clipboard", action: diagnostics.run)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(diagnostics.state == .collecting)
                    .accessibilityLabel("Copy Diagnostics")
                    .help("Copy call diagnostics")
            }
        }
    }
}
