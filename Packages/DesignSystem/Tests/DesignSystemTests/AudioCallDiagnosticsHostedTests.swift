#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.serialized)
    struct AudioCallDiagnosticsHostedTests {
        @MainActor
        private final class Collector {
            var requests = 0
            private var continuation: CheckedContinuation<Bool, Never>?

            func collect() async -> Bool {
                requests += 1
                return await withCheckedContinuation { continuation = $0 }
            }

            func finish(_ result: Bool) {
                continuation?.resume(returning: result)
                continuation = nil
            }
        }

        private func call(_ phase: AudioCallPhase) -> AudioCallSession {
            AudioCallSession(AudioCallSnapshot(
                id: UUID(),
                recipient: AudioCallRecipient(
                    conversationID: Conversation.ID("diagnostics-fixture"), memberID: Member.ID("peer"),
                    displayName: "Maya"
                ), direction: .outgoing, phase: phase
            ))
        }

        private func view(_ call: AudioCallSession, collector: Collector?) -> AudioCallView {
            AudioCallView(
                call: call,
                actions: AudioCallActions(
                    accept: {}, decline: {}, toggleMute: {}, hangUp: {},
                    copyDiagnostics: collector.map { collector in { await collector.collect() } }
                )
            )
        }

        /// Hosted the way the call window hosts it: content under a
        /// transparent titlebar, sized to fit.
        private func host(_ view: AudioCallView) -> (NSWindow, NSHostingView<AudioCallView>) {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: CallLayout.compact),
                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.orderFront(nil)
            window.displayIfNeeded()
            return (window, host)
        }

        /// A finished call's footnote sits on the stage's 22-point bottom
        /// margin, centered.
        private func clickCopy(_ window: NSWindow) throws {
            let point = NSPoint(x: CallLayout.compact.width / 2, y: 30)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1
                ))
                window.sendEvent(event)
            }
        }

        private func settle(_ host: NSView, until condition: () throws -> Bool) async rethrows -> Bool {
            for _ in 0 ..< 100 {
                host.layoutSubtreeIfNeeded()
                if try condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        /// A live call offers the same request from its device menu, which a
        /// posted click cannot open; a finished call shows it as a footnote.
        @Test(arguments: [AudioCallPhase.failed, .ended, .declined])
        func finishedCallsCollectOnlyOnClickAndCanRetry(phase: AudioCallPhase) async throws {
            let collector = Collector()
            let (window, host) = host(view(call(phase), collector: collector))
            defer { collector.finish(false); window.close() }
            host.layoutSubtreeIfNeeded()
            #expect(collector.requests == 0)
            try clickCopy(window)
            #expect(await settle(host) { collector.requests == 1 })
            try clickCopy(window)
            #expect(collector.requests == 1)
            collector.finish(false)
            #expect(try await settle(host) {
                try clickCopy(window)
                return collector.requests == 2
            })
            collector.finish(true)
        }

        @Test func replacingACallCancelsItsFeedbackAndDoesNotCollectForTheNewCall() async throws {
            let previous = Collector()
            let next = Collector()
            let (window, host) = host(view(call(.ended), collector: previous))
            defer { previous.finish(false); next.finish(false); window.close() }
            host.layoutSubtreeIfNeeded()
            try clickCopy(window)
            #expect(await settle(host) { previous.requests == 1 })
            host.rootView = view(call(.failed), collector: next)
            host.layoutSubtreeIfNeeded()
            previous.finish(true)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(next.requests == 0)
            #expect(try await settle(host) {
                try clickCopy(window)
                return next.requests == 1
            })
        }

        @Test func optionalFooterKeepsTheSameViewSizeAndRendersWithoutClipping() throws {
            let call = call(.failed)
            for offered in [false, true] {
                let renderer = ImageRenderer(content: view(call, collector: offered ? Collector() : nil))
                renderer.proposedSize = ProposedViewSize(CallLayout.compact)
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int(CallLayout.compact.width))
                #expect(image.height == Int(CallLayout.compact.height))
                if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_CAPTURE_DIR"] {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent(offered ? "with-diagnostics.png" : "without-diagnostics.png"))
                }
            }
        }
    }
#endif
