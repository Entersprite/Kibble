import ChatKit
import SwiftUI

/// Behind a call without video: a deep fixed gradient, colored by the
/// person's photo when there is one, the way Music colors its backdrop from
/// the artwork. Dragging it moves the window, since the titlebar is hidden.
/// It runs under the transparent titlebar to the window's edges.
struct CallBackdrop: View {
    let photo: URL?

    var body: some View {
        LinearGradient(colors: CallBackdrop.colors, startPoint: .top, endPoint: .bottom)
            .overlay {
                if let photo {
                    SceneImage(url: photo) { image in
                        image.resizable().scaledToFill().blur(radius: 70, opaque: true).opacity(0.5)
                    } placeholder: {
                        Color.clear
                    }
                }
            }
            .overlay(Color.black.opacity(0.18))
            .clipped()
            .windowDragArea()
            .accessibilityHidden(true)
            .ignoresSafeArea()
    }

    /// The avatar monogram's hue, darkened so white text and glass read on it.
    static let colors = [
        Color(red: 0x3B / 255, green: 0x37 / 255, blue: 0x4D / 255),
        Color(red: 0x14 / 255, green: 0x12 / 255, blue: 0x1C / 255)
    ]
}

/// The other person's video, filling the window behind the controls, under
/// the transparent titlebar included. A camera gets soft scrims so the window
/// buttons and the glass stay legible on any picture; a shared screen is
/// shown as it is, since a scrim over a light document reads as a gray band.
struct CallRemoteStage: View {
    let content: AnyView
    let isScreen: Bool

    var body: some View {
        ZStack {
            Color.black
            content
            if !isScreen {
                VStack(spacing: 0) {
                    scrim([.black.opacity(0.45), .clear]).frame(height: 90)
                    Spacer(minLength: 0)
                    scrim([.clear, .black.opacity(0.4)]).frame(height: 150)
                }
                .allowsHitTesting(false)
            }
            // The video draws in a platform view that keeps mouse events, so
            // a clear layer above it is what lets a drag move the window.
            Color.clear.contentShape(Rectangle()).windowDragArea()
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func scrim(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

/// The avatar, name and status in the middle of the stage.
struct CallPersonHeader: View {
    let call: AudioCallSnapshot
    let directory: [Member.ID: Member]
    let timing: CallTiming
    var avatarSize: CGFloat = 104
    var accountLabel: String?

    var body: some View {
        VStack(spacing: 16) {
            Avatar(member: call.recipient.memberID, directory: directory, size: avatarSize)
                .background {
                    if AudioCallPresentation.isWaiting(call.phase) {
                        CallWaitingHalo(size: avatarSize)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text(call.recipient.displayName)
                    .font(.title.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                CallStatusText(call: call, timing: timing)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let accountLabel {
                    Text(accountLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("On \(accountLabel)")
                }
                if let message = AudioCallPresentation.failureMessage(for: call) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300)
                        .padding(.top, 6)
                }
            }
        }
    }
}

/// The phase, a running timer while connected, or the final length once over.
struct CallStatusText: View {
    let call: AudioCallSnapshot
    let timing: CallTiming

    var body: some View {
        Group {
            if call.phase == .connected, let start = timing.connectedAt {
                Text(timerInterval: start ... Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .accessibilityLabel("Connected")
            } else if call.phase.isTerminal, let start = timing.connectedAt, let end = timing.endedAt {
                Text(AudioCallPresentation.status(for: call.phase)
                    + " · " + AudioCallPresentation.duration(end.timeIntervalSince(start)))
                    .monospacedDigit()
            } else {
                Text(AudioCallPresentation.status(for: call.phase))
            }
        }
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Two rings breathing out from the avatar while the call waits for an answer.
/// Still, rather than gone, when Reduce Motion is on.
struct CallWaitingHalo: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0 ..< 2, id: \.self) { ring in
                Circle()
                    .fill(.white.opacity(0.16))
                    .scaleEffect(expanded ? 1.55 : 1)
                    .opacity(expanded ? 0 : 1)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 2.4).repeatForever(autoreverses: false)
                            .delay(Double(ring) * 1.2),
                        value: expanded
                    )
            }
            if reduceMotion {
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2).padding(-8)
            }
        }
        .frame(width: size, height: size)
        .onAppear { expanded = !reduceMotion }
        .allowsHitTesting(false)
    }
}

/// Your own camera, in a corner of the stage.
struct CallSelfView: View {
    let content: AnyView

    var body: some View {
        content
            .frame(width: 192, height: 108)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
            .accessibilityElement()
            .accessibilityLabel("Your camera preview")
    }
}

/// What you are sharing, as the other person receives it: shown whole on
/// black, labeled "Sharing", with Stop Sharing on hover.
struct CallSharingPreview: View {
    let content: AnyView
    let width: CGFloat
    let stop: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        content
            .frame(width: width, height: (width * 10 / 16).rounded())
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                Label("Sharing", systemImage: "rectangle.on.rectangle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: .capsule)
                    .padding(8)
                    .accessibilityHidden(true)
            }
            .overlay {
                if isHovering, let stop {
                    Button("Stop Sharing", systemImage: "stop.fill", action: stop)
                        .buttonStyle(.glass)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview of your shared screen")
    }
}

/// The audio layout while sharing: the preview where the avatar was, the
/// name and timer beneath it.
struct CallSharingHeader: View {
    let call: AudioCallSnapshot
    let timing: CallTiming
    let content: AnyView
    let stop: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            CallSharingPreview(content: content, width: 300, stop: stop)
            VStack(spacing: 4) {
                Text(call.recipient.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
                CallStatusText(call: call, timing: timing)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Name and timer over the other person's video, in the titlebar's band.
/// Text only: content in that band takes no clicks.
struct CallVideoTitle: View {
    let call: AudioCallSnapshot
    let timing: CallTiming
    let isScreen: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isScreen {
                Image(systemName: "rectangle.on.rectangle")
                    .accessibilityLabel("Sharing their screen")
            }
            Text(call.recipient.displayName).fontWeight(.semibold).lineLimit(1)
            CallStatusText(call: call, timing: timing).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 340)
    }
}

/// A message about devices, sharing or diagnostics, above the controls.
struct CallNotice: Identifiable, Equatable {
    enum Kind { case info, warning, progress, success }
    let id: String
    let text: String
    let kind: Kind
}

struct CallNoticeView: View {
    let notice: CallNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
            Text(notice.text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .frame(maxWidth: 320)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch notice.kind {
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .progress:
            ProgressView().controlSize(.small).alignmentGuide(.firstTextBaseline) { $0.height * 0.75 }
        }
    }
}

private extension View {
    /// Lets a drag on otherwise empty stage move the window.
    @ViewBuilder func windowDragArea() -> some View {
        #if os(macOS)
            gesture(WindowDragGesture())
        #else
            self
        #endif
    }
}
