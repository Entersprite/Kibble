#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The pre-join controls' words, and hidden renders of the popovers that
    /// go with them. Renders are written out only where
    /// `KIBBLE_JOIN_SCREEN_RENDER_DIR` names a folder.
    @MainActor
    struct CallJoinScreenTests {
        @Test func aTryingControlIsShortInItsRowAndWholeForVoiceOver() {
            typealias Controls = CallMeetingPreparationControls
            #expect(Controls.microphoneTest(.off) == .init(title: "Test", label: "Test Microphone"))
            #expect(Controls.microphoneTest(.starting).label == "Cancel Microphone Test")
            #expect(Controls.microphoneTest(.active(0.4)) == .init(
                title: "Stop",
                label: "Stop Microphone Test"
            ))
            #expect(Controls.speakerTest(isPlaying: false).label == "Test Speakers")
            #expect(Controls.speakerTest(isPlaying: true).label == "Stop Speaker Test")
            let idle = CallPreparationCameraPreview(content: nil, isStarting: false, notice: nil, toggle: {})
            #expect(Controls.cameraPreview(idle) == .init(title: "Preview", label: "Preview Camera"))
            let starting = CallPreparationCameraPreview(
                content: nil,
                isStarting: true,
                notice: nil,
                toggle: {}
            )
            #expect(Controls.cameraPreview(starting).label == "Cancel Camera Preview")
            let showing = CallPreparationCameraPreview(
                content: AnyView(Color.black), isStarting: false, notice: nil, toggle: {}
            )
            #expect(Controls.cameraPreview(showing).label == "Stop Camera Preview")
        }

        @Test func everyDeviceStateFitsTheCompactColumn() throws {
            var blocked = CallMeetingPreparation(
                microphone: .needsPermission, camera: .accessOff, join: {}, cancel: {}
            )
            blocked.audioChecks = .init(
                microphone: .off, toggleMicrophone: nil, isPlaying: false, toggleSpeaker: nil,
                notice: "Allow microphone access in System Settings to test it here."
            )
            var joining = CallMeetingPreparation(microphone: .ready, camera: .ready, join: {}, cancel: {})
            joining.hasSpeaker = true
            joining.isJoining = true
            joining.audioSelection = .init(
                devices: CallAudioDevices(
                    microphones: [.init(id: "mic", name: "A Microphone With a Very Long Product Name")],
                    speakers: [.init(id: "out", name: "Studio Display Speakers")],
                    microphone: "mic", speaker: "out"
                ),
                selectMicrophone: { _ in }, selectSpeaker: { _ in }
            )
            joining.audioChecks = .init(
                microphone: .active(0.5), toggleMicrophone: {}, isPlaying: false, toggleSpeaker: {},
                notice: nil
            )
            let view = VStack(spacing: 24) {
                CallMeetingPreparationControls(preparation: blocked)
                CallMeetingPreparationControls(preparation: joining)
            }
            .padding(20)
            .frame(width: CallLayout.compact.width)
            .background(.black)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            let size = try render(view, name: "preparation-states")
            #expect(size.width == CallLayout.compact.width)
            // Each panel with its buttons takes well under half the window's height.
            #expect(size.height < CallLayout.compact.height * 1.2)
        }

        @Test func detailsAndTheMicrophoneMeterRender() throws {
            let details = try CallMeetingDetails(
                id: UUID(), url: #require(URL(string: "https://meet.example.test/abc-defg-hij")),
                dialIn: CallDialIn(phoneNumber: "+1 (202) 555-0142", pin: "012345678"),
                alternateDialIns: [CallDialIn(
                    phoneNumber: "+44 20 7946 0958",
                    pin: "987654321",
                    regionCode: "GB"
                )],
                attachments: [CallAgendaAttachment(
                    title: "Planning Agenda", url: #require(URL(string: "https://files.example.test/a"))
                )],
                copy: { _ in }, openPhoneNumbers: {}
            )
            let view = VStack(alignment: .leading, spacing: 20) {
                CallMeetingDetailsContent(details: details)
                CallMicrophoneLevelView(action: CallMicrophoneLevelAction(id: UUID(), isMuted: true) { nil })
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            let size = try render(view, name: "details-and-meter")
            #expect(size.width <= CallLayout.compact.width)
        }

        private func render(_ view: some View, name: String) throws -> CGSize {
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame.size = host.fittingSize
            // In a window that is never shown: glass draws nothing without one.
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: host.frame.size),
                styleMask: [.borderless], backing: .buffered, defer: true
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            defer { withExtendedLifetime(window) {} }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["KIBBLE_JOIN_SCREEN_RENDER_DIR"] {
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
            return host.frame.size
        }
    }
#endif
