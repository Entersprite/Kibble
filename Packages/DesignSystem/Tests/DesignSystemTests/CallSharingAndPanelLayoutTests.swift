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

        @Test func thePanelViewFillsItsWindowExactly() {
            let content = IncomingCallPanelContent(
                callID: UUID(), memberID: Member.ID("peer"), name: "Maya Okafor", person: nil
            )
            for hovering in [false, true] {
                let view = IncomingCallPanelView(
                    content: content, isHovering: hovering, accept: {}, decline: {}, open: {}, dismiss: {}
                )
                #expect(size(view) == IncomingCallPanelLayout.window)
            }
        }
    }
#endif
