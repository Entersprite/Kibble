#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The other person's muted microphone shows only when the provider says
    /// it is muted; unknown is never drawn as muted.
    @MainActor @Suite(.serialized)
    struct CallRemoteMutedBadgeTests {
        private let actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})

        private func call(_ phase: AudioCallPhase, remoteMuted: Bool?) -> AudioCallSession {
            AudioCallSession(AudioCallSnapshot(
                id: UUID(),
                recipient: AudioCallRecipient(
                    conversationID: Conversation.ID("badge-fixture"), memberID: Member.ID("peer"),
                    displayName: "Maya"
                ), direction: .outgoing, phase: phase, remoteMuted: remoteMuted
            ))
        }

        @Test func onlyAKnownMuteOnALiveCallShowsTheBadge() {
            #expect(AudioCallPresentation.showsRemoteMuted(call(.connected, remoteMuted: true)))
            #expect(AudioCallPresentation.showsRemoteMuted(call(.connecting, remoteMuted: true)))
            for value in [false, nil] as [Bool?] {
                #expect(!AudioCallPresentation.showsRemoteMuted(call(.connected, remoteMuted: value)))
            }
            for phase in [AudioCallPhase.ended, .failed, .declined, .unknown("future")] {
                #expect(!AudioCallPresentation.showsRemoteMuted(call(phase, remoteMuted: true)))
            }
        }

        @Test(arguments: [false, true])
        func theBadgeIsReadAsMutedOnlyWhenTheOtherPersonIsMuted(video: Bool) async throws {
            NSApplication.shared.accessibilitySetValue(
                true,
                forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            )
            let content = video ? CallVideoContent(remote: AnyView(Color.gray)) : nil
            for value in [true, false, nil] as [Bool?] {
                let host = NSHostingView(rootView: AudioCallView(
                    call: call(.connected, remoteMuted: value), actions: actions, video: content
                ))
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: CallLayout.video),
                    styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                // Positive control: the stage's controls are in the tree before
                // the badge's absence is believed.
                for _ in 0 ..< 100 where !labels(in: host).contains("End Call") {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                let found = labels(in: host)
                #expect(found.contains("End Call"), "\(found)")
                #expect(
                    found.contains("Muted") == (value == true),
                    "\(value.map(String.init) ?? "nil"): \(found)"
                )
            }
        }

        /// Set KIBBLE_CALL_CAPTURE_DIR to look at the badge: glass hides
        /// vibrant symbols offscreen, so judge its icon in the running app.
        @Test func theMutedStageRendersAtItsUsualSize() throws {
            for video in [false, true] {
                let content = video ? CallVideoContent(remote: AnyView(Color.gray)) : nil
                let renderer = ImageRenderer(content: AudioCallView(
                    call: call(.connected, remoteMuted: true), actions: actions, video: content
                ))
                let size = video ? CallLayout.video : CallLayout.compact
                renderer.proposedSize = ProposedViewSize(size)
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int(size.width))
                #expect(image.height == Int(size.height))
                if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_CAPTURE_DIR"] {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent(video ? "remote-muted-video.png" : "remote-muted-audio.png"))
                }
            }
        }

        private func labels(in node: NSObject) -> [String] {
            let labelSelector = NSSelectorFromString("accessibilityLabel")
            let childSelector = NSSelectorFromString("accessibilityChildren")
            let label = node.responds(to: labelSelector)
                ? node.perform(labelSelector)?.takeUnretainedValue() as? String : nil
            let children = node.responds(to: childSelector)
                ? node.perform(childSelector)?.takeUnretainedValue() as? [NSObject] : nil
            return (label.map { [$0] } ?? []) + (children ?? []).flatMap(labels(in:))
        }
    }
#endif
