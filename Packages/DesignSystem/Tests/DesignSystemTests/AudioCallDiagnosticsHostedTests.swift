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

        private func call(_ phase: AudioCallPhase) -> AudioCallSnapshot {
            AudioCallSnapshot(
                id: UUID(),
                recipient: AudioCallRecipient(
                    conversationID: Conversation.ID("diagnostics-fixture"), memberID: Member.ID("peer"),
                    displayName: "Maya"
                ), direction: .outgoing, phase: phase
            )
        }

        private func view(_ call: AudioCallSnapshot, collector: Collector?) -> AudioCallView {
            AudioCallView(
                call: call,
                actions: AudioCallActions(
                    accept: {}, decline: {}, toggleMute: {}, hangUp: {},
                    copyDiagnostics: collector.map { collector in { await collector.collect() } }
                )
            )
        }

        private func host(_ view: AudioCallView) -> (NSWindow, NSHostingView<AudioCallView>) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderFront(nil)
            window.displayIfNeeded()
            return (window, host)
        }

        private func clickCopy(_ window: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 190, y: 17), modifierFlags: [], timestamp: 0,
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

        @Test(arguments: [AudioCallPhase.connected, .failed, .ended])
        func activeAndTerminalCallsCollectOnlyOnClickAndCanRetry(phase: AudioCallPhase) async throws {
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
            host.rootView = view(call(.connected), collector: next)
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
                let renderer = ImageRenderer(content: view(call, collector: offered ? Collector() : nil)
                    .background(Color.white).environment(\.colorScheme, .light))
                renderer.proposedSize = ProposedViewSize(width: 380, height: 300)
                let image = try #require(renderer.cgImage)
                #expect(image.width == 380)
                #expect(image.height == 300)
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
