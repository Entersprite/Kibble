#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct CallSharingAndPanelLayoutTests {
        private func call(_ phase: AudioCallPhase) -> AudioCallSnapshot {
            AudioCallSnapshot(
                id: UUID(),
                recipient: AudioCallRecipient(
                    conversationID: Conversation.ID("layout"), memberID: Member.ID("peer"),
                    displayName: "Maya Okafor"
                ),
                direction: .outgoing, phase: phase
            )
        }

        private func size(_ view: some View) -> CGSize {
            NSHostingView(rootView: view).fittingSize
        }

        private let actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})

        /// The preview takes the avatar's place without growing the audio window.
        @Test func sharingInTheAudioLayoutKeepsTheWindowSize() {
            let screen = AnyView(Color.gray)
            let plain = size(AudioCallView(call: call(.connected), actions: actions))
            let sharing = size(AudioCallView(
                call: call(.connected), actions: actions,
                screenSharing: CallScreenShareState(phase: .sharing),
                screenPreview: screen
            ))
            #expect(sharing == plain)
            #expect(sharing.width == CallLayout.compact.width)
        }

        /// Every line the panel can show keeps it at its size, a failure on
        /// two lines and a long account name included.
        @Test func thePanelViewFillsItsWindowExactly() {
            let plain = IncomingCallPanelContent(
                callID: UUID(), memberID: Member.ID("peer"), name: "Maya Okafor", person: nil
            )
            var account = plain
            account.accountLabel = "someone.with.a.long.address@example.com"
            var ends = account
            ends.endsOtherCall = true
            var busy = ends
            busy.problem = "Another call is already using this device."
            var handoff = ends
            handoff.problem = "Couldn’t end the other call."
            var hidden = busy
            hidden.name = nil
            for content in [plain, account, ends, busy, handoff, hidden] {
                for hovering in [false, true] {
                    let view = IncomingCallPanelView(
                        content: content, isHovering: hovering, accept: {}, decline: {}, open: {}, dismiss: {}
                    )
                    #expect(size(view) == IncomingCallPanelLayout.window)
                }
            }
        }

        /// Call Back is drawn by hand so it stays green in a window that is
        /// not key; it still matches the glass Close beside it.
        @Test func callBackIsAsTallAsTheGlassButtonBesideIt() {
            let close = size(Button("Close") {}.buttonStyle(.glass).controlSize(.extraLarge))
            let callBack = size(CallBackButton {})
            #expect(close.height > 0)
            #expect(callBack.height == close.height)
        }

        /// The stage keeps clear of the titlebar through the safe area now,
        /// in a window built as the host builds it, and the window's size is
        /// what it was: the layout's own size plus the titlebar.
        @Test func theStageKeepsItsSizeUnderATransparentTitlebar() {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: CallLayout.compact),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: true
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let audio = NSHostingView(rootView: AudioCallView(call: call(.ringing), actions: actions))
            window.contentView = audio
            audio.layoutSubtreeIfNeeded()
            let titlebar = audio.safeAreaInsets.top
            // The positive control: the window has a titlebar to keep clear of.
            #expect(titlebar > 0)
            #expect(audio.fittingSize == CGSize(
                width: CallLayout.compact.width, height: CallLayout.compact.height + titlebar
            ))
            let video = NSHostingView(rootView: AudioCallView(
                call: call(.connected), actions: actions, video: CallVideoContent(remote: AnyView(Color.gray))
            ))
            window.contentView = video
            video.layoutSubtreeIfNeeded()
            #expect(video.fittingSize == CGSize(
                width: CallLayout.videoMinimum.width, height: CallLayout.videoMinimum.height + titlebar
            ))
            withExtendedLifetime(window) {}
        }
    }
#endif
