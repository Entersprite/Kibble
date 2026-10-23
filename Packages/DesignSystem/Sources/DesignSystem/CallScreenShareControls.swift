import SwiftUI

/// Local presentation state supplied by the host. Content titles and capture
/// identifiers are intentionally absent from the call surface.
public struct CallScreenShareState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, preparing, sharing, stopping }
    public var phase: Phase
    public var notice: String?
    /// The Mac's sound goes with the screen, by the person's explicit choice.
    public var sharesSound: Bool

    public init(phase: Phase = .idle, notice: String? = nil, sharesSound: Bool = false) {
        self.phase = phase; self.notice = notice; self.sharesSound = sharesSound
    }
}

/// Starts sharing through the system picker, and stops or cancels it. Lit
/// in the accent color from the moment the picker opens until sharing ends.
///
/// Where the host can send the Mac's sound too, a click while not sharing
/// opens a menu naming both choices, so sound is never shared by surprise;
/// while sharing, one click stops it.
struct CallScreenShareButton: View {
    let state: CallScreenShareState
    let toggle: () -> Void
    var shareWithSound: (() -> Void)?

    var body: some View {
        if state.phase == .idle, let shareWithSound {
            Menu {
                Button(CallMenu.sharingTitle(.idle), systemImage: "rectangle.on.rectangle", action: toggle)
                Button(CallMenu.shareWithSoundTitle, systemImage: "speaker.wave.2", action: shareWithSound)
            } label: {
                CallRoundFace(
                    title: title, symbol: "rectangle.on.rectangle", tone: .plain, size: CallLayout.button
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(title)
            .accessibilityLabel(title)
        } else {
            CallRoundButton(
                title: title,
                symbol: "rectangle.on.rectangle",
                tone: state.phase == .idle ? .plain : .active,
                action: toggle
            )
            .disabled(state.phase == .stopping)
        }
    }

    /// The menu bar's Call menu says the same (`CallMenu`).
    private var title: String {
        CallMenu.sharingTitle(state.phase)
    }
}
